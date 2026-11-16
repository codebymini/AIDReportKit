@file:UseSerializers(IsoInstantSerializer::class)

package io.github.codebymini.aidreport

import kotlinx.datetime.TimeZone
import kotlinx.datetime.toLocalDateTime
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.UseSerializers
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.min
import kotlin.math.sqrt
import kotlin.time.Instant

internal object Quantile {
    /**
     * Linear interpolation between closest ranks (Excel PERCENTILE.INC, NumPy default).
     * [sorted] must be ascending and non-empty; [p] is in 0..1.
     */
    fun value(p: Double, sorted: List<Double>): Double {
        require(sorted.isNotEmpty())
        val position = p.coerceIn(0.0, 1.0) * (sorted.size - 1)
        val lower = floor(position).toInt()
        val upper = min(lower + 1, sorted.size - 1)
        val fraction = position - lower
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
    }
}

/** The 5/25/50/75/95 percentiles used by AGP-style charts. */
@Serializable
public data class Percentiles(val p5: Double, val p25: Double, val p50: Double, val p75: Double, val p95: Double) {
    public companion object {
        /** `null` for empty input. */
        public fun of(values: List<Double>): Percentiles? {
            if (values.isEmpty()) return null
            val sorted = values.sorted()
            return Percentiles(
                p5 = Quantile.value(0.05, sorted),
                p25 = Quantile.value(0.25, sorted),
                p50 = Quantile.value(0.50, sorted),
                p75 = Quantile.value(0.75, sorted),
                p95 = Quantile.value(0.95, sorted),
            )
        }
    }
}

/** Range boundaries in mg/dL. Defaults follow the 2019 international consensus on time in range. */
@Serializable
public data class GlucoseThresholds(
    /** Below this is "very low" (level 2 hypoglycemia). */
    val veryLow: Double = 54.0,
    /** Below this is "low". */
    val low: Double = 70.0,
    /** Above this is "high". */
    val high: Double = 180.0,
    /** Above this is "very high". */
    val veryHigh: Double = 250.0,
    /** Upper bound of time in tight range (TITR); the lower bound is [low]. */
    val tightHigh: Double = 140.0,
) {
    public companion object {
        public val consensus: GlucoseThresholds = GlucoseThresholds()
    }
}

/** Fractions (0..1) of sensor readings in each band. The five main bands sum to 1. */
@Serializable
public data class TimeInRanges(
    /** `< veryLow` */
    val veryLow: Double,
    /** `veryLow ..< low` */
    val low: Double,
    /** `low ... high` */
    val inRange: Double,
    /** `high <.. veryHigh` */
    val high: Double,
    /** `> veryHigh` */
    val veryHigh: Double,
    /** `low ... tightHigh`; overlaps [inRange]. */
    val tightRange: Double,
) {
    val below: Double get() = veryLow + low
    val above: Double get() = high + veryHigh

    public companion object {
        public fun of(values: List<Double>, thresholds: GlucoseThresholds): TimeInRanges {
            val n = maxOf(values.size, 1).toDouble()
            fun share(predicate: (Double) -> Boolean): Double = values.count(predicate) / n
            return TimeInRanges(
                veryLow = share { it < thresholds.veryLow },
                low = share { it >= thresholds.veryLow && it < thresholds.low },
                inRange = share { it >= thresholds.low && it <= thresholds.high },
                high = share { it > thresholds.high && it <= thresholds.veryHigh },
                veryHigh = share { it > thresholds.veryHigh },
                tightRange = share { it >= thresholds.low && it <= thresholds.tightHigh },
            )
        }
    }
}

/**
 * Glycemia Risk Index (Klonoff et al. 2023).
 *
 * Always computed from the fixed consensus thresholds (54/70/180/250 mg/dL), regardless of the
 * user's target range or display unit, so scores are comparable across people and apps.
 */
@Serializable
public data class GlycemiaRiskIndex(
    /** Percent (0..100) of readings in each band. */
    val veryLowPercent: Double,
    val lowPercent: Double,
    val highPercent: Double,
    val veryHighPercent: Double,
    /** `veryLow + 0.8 × low` */
    val hypoComponent: Double,
    /** `veryHigh + 0.5 × high` */
    val hyperComponent: Double,
    /** `3.0 × hypo + 1.6 × hyper`, before capping. */
    val uncappedScore: Double,
    /** 0..100 */
    val score: Double,
    val zone: Zone,
) {
    @Serializable
    public enum class Zone { A, B, C, D, E }

    val weightedHypoComponent: Double get() = 3.0 * hypoComponent
    val weightedHyperComponent: Double get() = 1.6 * hyperComponent

    public companion object {
        public fun of(values: List<Double>): GlycemiaRiskIndex {
            val tir = TimeInRanges.of(values, GlucoseThresholds.consensus)
            val veryLow = tir.veryLow * 100
            val low = tir.low * 100
            val high = tir.high * 100
            val veryHigh = tir.veryHigh * 100
            val hypo = veryLow + 0.8 * low
            val hyper = veryHigh + 0.5 * high
            val uncapped = 3.0 * hypo + 1.6 * hyper
            val score = minOf(100.0, uncapped)
            val zone = when {
                score <= 20 -> Zone.A
                score <= 40 -> Zone.B
                score <= 60 -> Zone.C
                score <= 80 -> Zone.D
                else -> Zone.E
            }
            return GlycemiaRiskIndex(veryLow, low, high, veryHigh, hypo, hyper, uncapped, score, zone)
        }
    }
}

/** Summary statistics for sensor glucose over an interval. All values in mg/dL. */
@Serializable
public data class GlucoseStatistics(
    val readingCount: Int,
    val mean: Double,
    /** Sample standard deviation (n − 1). */
    val standardDeviation: Double,
    /** SD / mean, as a fraction. ≤ 0.36 is the consensus stability target. */
    val coefficientOfVariation: Double,
    /** Glucose Management Indicator, % (3.31 + 0.02392 × mean mg/dL). */
    val gmi: Double,
    val minimum: Double,
    val maximum: Double,
    val percentiles: Percentiles,
    val timeInRanges: TimeInRanges,
    val gri: GlycemiaRiskIndex,
    /**
     * Fraction of `slotDuration` slots in the interval with at least one reading. ≥ 0.70 over 14
     * days is the consensus minimum for reliable statistics.
     */
    val coverage: Double,
) {
    /**
     * Estimated A1c, % (NGSP), from the ADAG relation (mean mg/dL + 46.7) / 28.7, as Trio and
     * LoopFollow show it next to GMI.
     */
    val estimatedA1c: Double get() = (mean + 46.7) / 28.7

    /** Estimated A1c in mmol/mol (IFCC), converted the way Trio does: 10.929 × (NGSP − 2.152). */
    val estimatedA1cMmolMol: Double get() = 10.929 * (estimatedA1c - 2.152)

    public companion object {
        /** Sensor readings only; `null` when there are none in the interval. */
        public fun compute(
            readings: List<GlucoseReading>,
            interval: DateInterval,
            thresholds: GlucoseThresholds = GlucoseThresholds.consensus,
            slotDuration: Double = 300.0,
        ): GlucoseStatistics? {
            val sensor = readings.filter { it.kind == GlucoseReading.Kind.SENSOR && interval.containsHalfOpen(it.date) }
            val values = sensor.map { it.mgdL }
            val percentiles = Percentiles.of(values) ?: return null
            val n = values.size.toDouble()
            val mean = values.fold(0.0) { total, value -> total + value } / n
            val variance = if (values.size > 1) values.fold(0.0) { total, value -> total + (value - mean) * (value - mean) } / (n - 1) else 0.0
            val sd = sqrt(variance)
            return GlucoseStatistics(
                readingCount = values.size,
                mean = mean,
                standardDeviation = sd,
                coefficientOfVariation = if (mean > 0) sd / mean else 0.0,
                gmi = 3.31 + 0.02392 * mean,
                minimum = values.min(),
                maximum = values.max(),
                percentiles = percentiles,
                timeInRanges = TimeInRanges.of(values, thresholds),
                gri = GlycemiaRiskIndex.of(values),
                coverage = coverage(sensor.map { it.date }, interval, slotDuration),
            )
        }

        /**
         * Fraction of [slotDuration]-second slots in [interval] that contain at least one date.
         * Works for both 1-minute (Libre) and 5-minute (Dexcom) sensors.
         */
        public fun coverage(dates: List<Instant>, interval: DateInterval, slotDuration: Double = 300.0): Double {
            val slotCount = ceil(interval.duration / slotDuration).toInt()
            if (slotCount <= 0) return 0.0
            val filled = dates.filter { interval.containsHalfOpen(it) }
                .map { (it.secondsSince(interval.start) / slotDuration).toInt() }
                .toSet()
            return filled.size.toDouble() / slotCount
        }
    }
}

@Serializable
public data class InsulinStatistics(
    val totalUnits: Double,
    /** Scheduled + temp basal. */
    val basalUnits: Double,
    val bolusUnits: Double,
    /** User-initiated boluses delivered by the pump. */
    val manualBolusUnits: Double,
    /** SMBs / automatic boluses. */
    val automaticBolusUnits: Double,
    /** Logged, not pump-delivered (pen, inhaled). */
    val externalBolusUnits: Double,
    val bolusCount: Int,
    val automaticBolusCount: Int,
    /** Seconds. */
    val suspendedDuration: Double,
    /** Interval length in days (fractional for partial days). */
    val days: Double,
    /** Total daily dose: `totalUnits / days`. */
    val averageDailyDose: Double,
    /** `basalUnits / totalUnits` (0 when there is no insulin). */
    val basalFraction: Double,
    /**
     * Fraction of the interval covered by basal records. Below ~0.9 the basal total undercounts;
     * provide a [BasalSchedule] so gaps are filled with scheduled basal.
     */
    val basalCoverage: Double,
    /**
     * What the basal schedule (the profile programmed in the app) would have delivered over the
     * time there is data, before any temp basal or suspension; `null` without a schedule. Compare
     * with [basalUnits], what was delivered, to see how far the loop moved basal.
     */
    val programmedBasalUnits: Double? = null,
) {
    // Per-day averages (what reports show; the totals above depend on the period length)

    val averageDailyBasal: Double get() = perDay(basalUnits)
    val averageDailyProgrammedBasal: Double? get() = programmedBasalUnits?.let(::perDay)

    /** Delivered basal as a share of programmed basal (1 = as scheduled); `null` without a schedule. */
    val deliveredBasalFraction: Double?
        get() {
            val programmed = programmedBasalUnits ?: return null
            return if (programmed > 0) basalUnits / programmed else null
        }
    val averageDailyBolus: Double get() = perDay(bolusUnits)
    val averageDailyManualBolus: Double get() = perDay(manualBolusUnits)
    val averageDailyAutomaticBolus: Double get() = perDay(automaticBolusUnits)
    val averageDailyExternalBolus: Double get() = perDay(externalBolusUnits)

    /** Boluses of any kind per day. */
    val averageDailyBolusCount: Double get() = perDay(bolusCount.toDouble())
    val averageDailyAutomaticBolusCount: Double get() = perDay(automaticBolusCount.toDouble())

    /** Suspended time per day, in seconds. */
    val averageDailySuspendedDuration: Double get() = perDay(suspendedDuration)

    private fun perDay(total: Double): Double = if (days > 0) total / days else 0.0

    public companion object {
        /**
         * @param schedule The basal schedule, for [programmedBasalUnits].
         * @param window The time there is data. Programmed basal only counts there, as delivered
         *   basal does, so a period that starts before the first record is not read as a shortfall.
         */
        public fun compute(
            doses: List<InsulinDose>,
            interval: DateInterval,
            schedule: BasalSchedule? = null,
            window: DateInterval? = null,
        ): InsulinStatistics {
            val clamped = doses.mapNotNull { it.clamped(interval) }
            val boluses = clamped.filter { it.kind == InsulinDose.Kind.BOLUS }
            val basal = clamped.filter { it.kind == InsulinDose.Kind.BASAL || it.kind == InsulinDose.Kind.TEMP_BASAL }
            val suspends = clamped.filter { it.kind == InsulinDose.Kind.SUSPEND }

            fun List<InsulinDose>.units(): Double = fold(0.0) { total, dose -> total + dose.units }
            val basalUnits = basal.units()
            val bolusUnits = boluses.units()
            val automatic = boluses.filter { it.isAutomatic && !it.isExternal }
            val external = boluses.filter { it.isExternal }
            val total = basalUnits + bolusUnits
            val days = interval.duration / 86400

            return InsulinStatistics(
                totalUnits = total,
                basalUnits = basalUnits,
                bolusUnits = bolusUnits,
                manualBolusUnits = bolusUnits - automatic.units() - external.units(),
                automaticBolusUnits = automatic.units(),
                externalBolusUnits = external.units(),
                bolusCount = boluses.size,
                automaticBolusCount = automatic.size,
                suspendedDuration = suspends.fold(0.0) { sum, dose -> sum + dose.duration },
                days = days,
                averageDailyDose = if (days > 0) total / days else 0.0,
                basalFraction = if (total > 0) basalUnits / total else 0.0,
                basalCoverage = BasalTimeline.coverage(clamped, interval),
                programmedBasalUnits = schedule?.let { scheduled ->
                    val span = interval.intersection(window ?: interval)
                    if (span == null || span.duration <= 0) 0.0 else scheduled.doses(span).units()
                },
            )
        }
    }
}

@Serializable
public data class CarbStatistics(
    /** Carbs actually entered; excludes fat/protein equivalents. */
    val totalGrams: Double,
    /** Entries with carbs; a fat/protein-only meal is not counted. */
    val entryCount: Int,
    val averagePerEntry: Double,
    val largestEntry: Double,
    val days: Double,
    val averageDailyGrams: Double,
    val totalFatGrams: Double,
    val totalProteinGrams: Double,
    /** Carb equivalents generated from fat/protein (Trio FPU), reported separately. */
    val fatProteinEquivalentGrams: Double,
) {
    // Per-day averages (what reports show; the totals above depend on the period length)

    /** Carb entries per day. */
    val averageDailyEntryCount: Double get() = perDay(entryCount.toDouble())
    val averageDailyFatGrams: Double get() = perDay(totalFatGrams)
    val averageDailyProteinGrams: Double get() = perDay(totalProteinGrams)
    val averageDailyFatProteinEquivalentGrams: Double get() = perDay(fatProteinEquivalentGrams)

    private fun perDay(total: Double): Double = if (days > 0) total / days else 0.0

    public companion object {
        public fun compute(entries: List<CarbIntake>, interval: DateInterval): CarbStatistics {
            val inInterval = entries.filter { interval.containsHalfOpen(it.date) }
            val carbs = inInterval.filter { !it.isFatProteinEquivalent }
            // A fat/protein-only meal (Trio stores it as an entry with 0 g of carbs) still carries
            // its fat and protein, but it is not a carb entry.
            val carbEntries = carbs.filter { it.grams > 0 }
            val total = carbEntries.fold(0.0) { sum, entry -> sum + entry.grams }
            val days = interval.duration / 86400
            return CarbStatistics(
                totalGrams = total,
                entryCount = carbEntries.size,
                averagePerEntry = if (carbEntries.isEmpty()) 0.0 else total / carbEntries.size,
                largestEntry = carbEntries.maxOfOrNull { it.grams } ?: 0.0,
                days = days,
                averageDailyGrams = if (days > 0) total / days else 0.0,
                totalFatGrams = carbs.fold(0.0) { sum, entry -> sum + (entry.fatGrams ?: 0.0) },
                totalProteinGrams = carbs.fold(0.0) { sum, entry -> sum + (entry.proteinGrams ?: 0.0) },
                fatProteinEquivalentGrams = inInterval.filter { it.isFatProteinEquivalent }.fold(0.0) { sum, entry -> sum + entry.grams },
            )
        }
    }
}

/**
 * Glucose by time of day, all days overlaid: percentiles (the Ambulatory Glucose Profile) and the
 * share of readings in each range.
 */
@Serializable
public data class AGPProfile(val bucketMinutes: Int, val buckets: List<Bucket>) {
    @Serializable
    public data class Bucket(
        /** Minutes after local midnight where this bucket starts. */
        val startMinute: Int,
        val readingCount: Int,
        /** `null` when the bucket has no readings. */
        val percentiles: Percentiles? = null,
        /** Share of this bucket's readings in each range; `null` when the bucket has no readings. */
        val timeInRanges: TimeInRanges? = null,
    )

    public companion object {
        public fun compute(
            readings: List<GlucoseReading>,
            timeZone: TimeZone,
            bucketMinutes: Int = 60,
            thresholds: GlucoseThresholds = GlucoseThresholds.consensus,
        ): AGPProfile {
            val size = bucketMinutes.coerceIn(5, 1440)
            val bucketCount = ceil(1440.0 / size).toInt()
            val values = List(bucketCount) { mutableListOf<Double>() }
            for (reading in readings) {
                if (reading.kind != GlucoseReading.Kind.SENSOR) continue
                val local = reading.date.toLocalDateTime(timeZone)
                val minute = local.hour * 60 + local.minute
                values[min(minute / size, bucketCount - 1)] += reading.mgdL
            }
            val buckets = values.mapIndexed { index, bucket ->
                Bucket(
                    startMinute = index * size,
                    readingCount = bucket.size,
                    percentiles = Percentiles.of(bucket),
                    timeInRanges = if (bucket.isEmpty()) null else TimeInRanges.of(bucket, thresholds),
                )
            }
            return AGPProfile(size, buckets)
        }
    }
}

/** Time in ranges for one part of the day, all days overlaid, on the report's clock. */
@Serializable
public data class DayPeriodRanges(
    val period: Period,
    val readingCount: Int,
    /** `null` when the period has no sensor readings. */
    val timeInRanges: TimeInRanges? = null,
) {
    /**
     * Night, morning, afternoon and evening: the same six-hour parts of the day as LoopFollow's
     * time-in-range statistics.
     */
    @Serializable
    public enum class Period(
        /** Hours of the day, end excluded: 0–6, 6–12, 12–18, 18–24. */
        public val hours: IntRange,
        public val title: String,
    ) {
        @SerialName("night") NIGHT(0 until 6, "Night"),
        @SerialName("morning") MORNING(6 until 12, "Morning"),
        @SerialName("afternoon") AFTERNOON(12 until 18, "Afternoon"),
        @SerialName("evening") EVENING(18 until 24, "Evening");

        /** The hours as printed, e.g. "06–12". */
        public val hoursText: String get() = "${padded(hours.first, 2)}–${padded(hours.last + 1, 2)}"

        public companion object {
            public fun of(hour: Int): Period = entries.firstOrNull { hour in it.hours } ?: EVENING
        }
    }

    public companion object {
        /** One entry per period, in order, from sensor readings only. */
        public fun compute(
            readings: List<GlucoseReading>,
            timeZone: TimeZone,
            thresholds: GlucoseThresholds = GlucoseThresholds.consensus,
        ): List<DayPeriodRanges> {
            val values = mutableMapOf<Period, MutableList<Double>>()
            for (reading in readings) {
                if (reading.kind != GlucoseReading.Kind.SENSOR) continue
                values.getOrPut(Period.of(reading.date.toLocalDateTime(timeZone).hour)) { mutableListOf() } += reading.mgdL
            }
            return Period.entries.map { period ->
                val periodValues = values[period].orEmpty()
                DayPeriodRanges(
                    period = period,
                    readingCount = periodValues.size,
                    timeInRanges = if (periodValues.isEmpty()) null else TimeInRanges.of(periodValues, thresholds),
                )
            }
        }
    }
}

/**
 * The first and last data point of a report.
 *
 * A rolling range starts and ends mid-day, so its first and last calendar days hold less than a
 * day of data and look smaller in every per-day chart. Reports warn about that when the data
 * starts or ends more than [MIDNIGHT_TOLERANCE] from midnight on the data's own clock (the
 * looper's time zone, which for a follower app is not the device's).
 */
@Serializable
public data class DataSpan(val first: Instant, val last: Instant) {
    /** Whether the first data point is more than [tolerance] seconds from midnight, on either side. */
    public fun isFirstDayPartial(timeZone: TimeZone, tolerance: Double = MIDNIGHT_TOLERANCE): Boolean =
        distanceToMidnight(first, timeZone) > tolerance

    /** Whether the last data point is more than [tolerance] seconds from midnight, on either side. */
    public fun isLastDayPartial(timeZone: TimeZone, tolerance: Double = MIDNIGHT_TOLERANCE): Boolean =
        distanceToMidnight(last, timeZone) > tolerance

    public companion object {
        /** Data starting or ending within this many seconds of midnight counts as a whole day: two missed five-minute sensor readings. */
        public const val MIDNIGHT_TOLERANCE: Double = 600.0

        /** Seconds to the nearest midnight, before or after [date], on the clock of [timeZone]. */
        public fun distanceToMidnight(date: Instant, timeZone: TimeZone): Double {
            val dayStart = timeZone.startOfDay(date)
            val sinceMidnight = date.secondsSince(dayStart)
            val nextMidnight = timeZone.addingDays(1, dayStart)
            return minOf(sinceMidnight, nextMidnight.secondsSince(date))
        }
    }
}

/** The first and last data point of any kind inside the interval; `null` when there is none. */
public val TherapyDataset.dataSpan: DataSpan?
    get() {
        val doses = insulin.flatMap { listOf(maxOf(it.start, interval.start), minOf(it.end, interval.end)) }
        val dates = (glucose.map { it.date } + carbs.map { it.date } + doses).filter { it >= interval.start && it <= interval.end }
        val first = dates.minOrNull() ?: return null
        return DataSpan(first, dates.max())
    }

@Serializable
public data class TherapySummary(
    val interval: DateInterval,
    /** `null` when there are no sensor readings. */
    val glucose: GlucoseStatistics? = null,
    val insulin: InsulinStatistics,
    val carbs: CarbStatistics,
)

@Serializable
public data class DailySummary(
    /** Local midnight of the day (in the dataset's time zone). */
    val day: Instant,
    /** The part of that day inside the report interval (first/last days can be partial). */
    val interval: DateInterval,
    val glucose: GlucoseStatistics? = null,
    val insulin: InsulinStatistics,
    val carbs: CarbStatistics,
)

/** Turns a (sanitized) dataset into summary, per-day and time-of-day statistics. */
public class StatsAggregator(
    public val thresholds: GlucoseThresholds = GlucoseThresholds.consensus,
    public val timeZone: TimeZone = TimeZone.currentSystemDefault(),
    public val agpBucketMinutes: Int = 60,
    /** For programmed basal next to delivered basal; `null` leaves it out. */
    public val basalSchedule: BasalSchedule? = null,
) {
    public fun summary(dataset: TherapyDataset): TherapySummary = summary(dataset, dataset.interval, dataWindow(dataset))

    public fun daily(dataset: TherapyDataset): List<DailySummary> {
        val window = dataWindow(dataset)
        return dayIntervals(dataset.interval).map { (day, interval) ->
            val summary = summary(dataset, interval, window)
            DailySummary(day, interval, summary.glucose, summary.insulin, summary.carbs)
        }
    }

    public fun dayPeriods(dataset: TherapyDataset): List<DayPeriodRanges> =
        DayPeriodRanges.compute(dataset.glucose, timeZone, thresholds)

    public fun agp(dataset: TherapyDataset): AGPProfile =
        AGPProfile.compute(dataset.glucose, timeZone, agpBucketMinutes, thresholds)

    /** From the first to the last data point: where programmed basal is counted. */
    private fun dataWindow(dataset: TherapyDataset): DateInterval? = dataset.dataSpan?.let { DateInterval(it.first, it.last) }

    private fun summary(dataset: TherapyDataset, interval: DateInterval, dataWindow: DateInterval?): TherapySummary = TherapySummary(
        interval = interval,
        glucose = GlucoseStatistics.compute(dataset.glucose, interval, thresholds),
        insulin = InsulinStatistics.compute(dataset.insulin, interval, basalSchedule, dataWindow),
        carbs = CarbStatistics.compute(dataset.carbs, interval),
    )

    /** Calendar days intersecting [interval], clipped to it. */
    internal fun dayIntervals(interval: DateInterval): List<Pair<Instant, DateInterval>> {
        val result = mutableListOf<Pair<Instant, DateInterval>>()
        var dayStart = timeZone.startOfDay(interval.start)
        while (dayStart < interval.end) {
            val next = timeZone.addingDays(1, dayStart)
            val start = maxOf(dayStart, interval.start)
            val end = minOf(next, interval.end)
            if (end > start) result += dayStart to DateInterval(start, end)
            dayStart = next
        }
        return result
    }
}
