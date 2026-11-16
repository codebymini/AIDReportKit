@file:UseSerializers(IsoInstantSerializer::class)

package io.github.codebymini.aidreport

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.UseSerializers
import kotlin.jvm.JvmInline
import kotlin.math.abs
import kotlin.time.Instant

/** Limits used by validation rules and the sanitizer. Glucose values in mg/dL, times in seconds. */
@Serializable
public data class ValidationConfiguration(
    /** Readings outside `minimumPlausibleGlucose..maximumPlausibleGlucose` are errors. */
    val minimumPlausibleGlucose: Double = 20.0,
    val maximumPlausibleGlucose: Double = 600.0,
    /** Rate of change above this (mg/dL per minute) between consecutive sensor readings is flagged. */
    val maximumGlucoseRateOfChange: Double = 6.0,
    /** Sensor gaps longer than this are reported. */
    val maximumGlucoseGap: Double = 15 * 60.0,
    /**
     * Two records of the same kind closer than this with the same value are duplicates. Kept below
     * 60 s so 1-minute Libre readings are not flagged.
     */
    val duplicateWindow: Double = 30.0,
    /** Minimum CGM coverage before statistics are flagged as unreliable (consensus: 70%). */
    val minimumGlucoseCoverage: Double = 0.70,
    /** Reports shorter than this get an info note (consensus: 14 days for GMI/TIR). */
    val recommendedSpan: Double = 14 * 86400.0,
    val maximumBolus: Double = 25.0,
    val maximumBasalRate: Double = 10.0,
    val maximumCarbEntry: Double = 250.0,
    /** Basal records should cover at least this fraction of the interval. */
    val minimumBasalCoverage: Double = 0.90,
    /** Records later than `now + futureTolerance` are errors (clock or time-zone problems). */
    val futureTolerance: Double = 5 * 60.0,
    /** At most this many issues per code are kept; the rest are summarized. */
    val maximumIssuesPerCode: Int = 25,
)

/**
 * Stable, machine-readable issue identifier, e.g. `glucose.likelyMmolL`. Hosts can declare their
 * own codes with `ValidationCode("…")`.
 */
@Serializable
@JvmInline
public value class ValidationCode(public val rawValue: String) {
    /** The part before the first dot: `glucose`, `insulin`, `carbs`, `dataset`. */
    public val category: String get() = rawValue.substringBefore('.')

    override fun toString(): String = rawValue

    public companion object {
        public val glucoseNoData: ValidationCode = ValidationCode("glucose.noData")
        public val glucoseImplausibleValue: ValidationCode = ValidationCode("glucose.implausibleValue")
        public val glucoseLikelyMmolL: ValidationCode = ValidationCode("glucose.likelyMmolL")
        public val glucoseDuplicate: ValidationCode = ValidationCode("glucose.duplicate")
        public val glucoseRateOfChange: ValidationCode = ValidationCode("glucose.rateOfChange")
        public val glucoseGap: ValidationCode = ValidationCode("glucose.gap")
        public val glucoseLowCoverage: ValidationCode = ValidationCode("glucose.lowCoverage")

        public val insulinNoData: ValidationCode = ValidationCode("insulin.noData")
        public val insulinNegative: ValidationCode = ValidationCode("insulin.negative")
        public val insulinEndBeforeStart: ValidationCode = ValidationCode("insulin.endBeforeStart")
        public val insulinBolusAboveMax: ValidationCode = ValidationCode("insulin.bolusAboveMax")
        public val insulinBasalRateAboveMax: ValidationCode = ValidationCode("insulin.basalRateAboveMax")
        public val insulinBasalOverlap: ValidationCode = ValidationCode("insulin.basalOverlap")
        public val insulinDuplicateBolus: ValidationCode = ValidationCode("insulin.duplicateBolus")
        public val insulinLowBasalCoverage: ValidationCode = ValidationCode("insulin.lowBasalCoverage")

        public val carbsNegative: ValidationCode = ValidationCode("carbs.negative")
        public val carbsAboveMax: ValidationCode = ValidationCode("carbs.aboveMax")
        public val carbsDuplicate: ValidationCode = ValidationCode("carbs.duplicate")

        public val datasetFutureTimestamp: ValidationCode = ValidationCode("dataset.futureTimestamp")
        public val datasetShortSpan: ValidationCode = ValidationCode("dataset.shortSpan")
        public val validationTruncated: ValidationCode = ValidationCode("validation.truncated")
    }
}

@Serializable
public data class ValidationIssue(
    val code: ValidationCode,
    val severity: Severity,
    val message: String,
    val date: Instant? = null,
    @SerialName("sourceID") val sourceId: String? = null,
) {
    /** Ordered from least to most serious. */
    @Serializable
    public enum class Severity {
        /** Worth knowing; statistics are still valid. */
        @SerialName("info") INFO,

        /** Statistics may be skewed (e.g. low coverage, duplicates that the sanitizer removed). */
        @SerialName("warning") WARNING,

        /** The data is wrong (e.g. mmol/L delivered as mg/dL); statistics should not be trusted. */
        @SerialName("error") ERROR,
    }
}

@Serializable
public data class ValidationReport(val issues: List<ValidationIssue> = emptyList()) {
    val hasErrors: Boolean get() = issues.any { it.severity == ValidationIssue.Severity.ERROR }

    public fun issuesAtLeast(severity: ValidationIssue.Severity): List<ValidationIssue> = issues.filter { it.severity >= severity }

    public fun count(severity: ValidationIssue.Severity): Int = issues.count { it.severity == severity }

    public fun issuesWithCode(code: ValidationCode): List<ValidationIssue> = issues.filter { it.code == code }
}

/** One check over a dataset. Add custom rules by implementing it and passing them to [DatasetValidator]. */
public fun interface ValidationRule {
    public fun validate(dataset: TherapyDataset, configuration: ValidationConfiguration, now: Instant): List<ValidationIssue>
}

/**
 * Runs validation rules over a raw dataset — before sanitizing — so adapter and data problems are
 * reported rather than silently hidden.
 */
public class DatasetValidator(
    public val rules: List<ValidationRule> = standardRules,
    public val configuration: ValidationConfiguration = ValidationConfiguration(),
) {
    public fun validate(dataset: TherapyDataset, now: Instant): ValidationReport {
        val issues = rules.flatMap { it.validate(dataset, configuration, now) }
        return ValidationReport(capped(issues))
    }

    /** Keeps the first `maximumIssuesPerCode` issues of each code and summarizes the rest. */
    private fun capped(issues: List<ValidationIssue>): List<ValidationIssue> {
        val limit = configuration.maximumIssuesPerCode
        val counts = linkedMapOf<ValidationCode, Int>()
        val kept = mutableListOf<ValidationIssue>()
        for (issue in issues) {
            val count = (counts[issue.code] ?: 0) + 1
            counts[issue.code] = count
            if (count <= limit) kept += issue
        }
        val summaries = counts.filter { it.value > limit }.entries
            .sortedBy { it.key.rawValue }
            .map { (code, count) ->
                ValidationIssue(ValidationCode.validationTruncated, ValidationIssue.Severity.INFO, Text.moreIssues(count - limit, code))
            }
        return (kept + summaries).sortedWith(
            compareByDescending<ValidationIssue> { it.severity }.thenBy { it.date ?: Instant.DISTANT_PAST },
        )
    }

    public companion object {
        public val standardRules: List<ValidationRule> = listOf(
            GlucoseValueRule,
            GlucoseDuplicateRule,
            GlucoseContinuityRule,
            InsulinValueRule,
            InsulinConsistencyRule,
            CarbRule,
            DatasetTimingRule,
        )
    }
}

/**
 * Produces the dataset statistics are computed from: drops implausible and future records,
 * removes duplicates, ends overlapping temp basals and (optionally) fills basal gaps from a
 * schedule. Does not fix unit errors — those are adapter bugs and are reported as errors.
 */
public class DatasetSanitizer(
    public val configuration: ValidationConfiguration = ValidationConfiguration(),
    public val basalSchedule: BasalSchedule? = null,
) {
    public fun sanitize(dataset: TherapyDataset, now: Instant): TherapyDataset {
        val c = configuration
        val latest = now.plusSeconds(c.futureTolerance)

        val glucose = Dedupe.glucose(
            dataset.glucose.filter { it.date <= latest && it.mgdL >= c.minimumPlausibleGlucose && it.mgdL <= c.maximumPlausibleGlucose },
            c.duplicateWindow,
        ).kept

        val validDoses = dataset.insulin.filter { it.units >= 0 && it.end >= it.start && it.start <= latest }
        val boluses = Dedupe.boluses(validDoses.filter { it.kind == InsulinDose.Kind.BOLUS }, c.duplicateWindow).kept
        var insulin = BasalTimeline.truncatingOverlaps(boluses + validDoses.filter { it.isBasalLike })
        val carbs = Dedupe.carbs(dataset.carbs.filter { it.grams >= 0 && it.date <= latest }, c.duplicateWindow).kept

        // Scheduled basal is only assumed while the app demonstrably had data: between the first
        // and last record of any kind. Before/after that (new install, uploader offline) it stays empty.
        val schedule = basalSchedule
        if (schedule != null) {
            val limit = minOf(dataset.interval.end, now)
            val recordDates = (glucose.map { it.date } + insulin.flatMap { listOf(it.start, it.end) } + carbs.map { it.date })
                .filter { it >= dataset.interval.start && it <= limit }
            val first = recordDates.minOrNull()
            val last = recordDates.maxOrNull()
            if (first != null && last != null && last > first) {
                insulin = BasalTimeline.fillingGaps(insulin, DateInterval(first, last), schedule)
            }
        }

        return TherapyDataset(dataset.interval, dataset.source, glucose, insulin, carbs).restricted(dataset.interval)
    }
}

/** Shared duplicate detection, used by both validation rules (to report) and the sanitizer (to drop). */
internal object Dedupe {
    data class Split<T>(val kept: List<T>, val duplicates: List<T>)

    /**
     * Splits [items] into kept and duplicate records. A record is a duplicate when its non-null
     * source id was already seen, or when an already-kept record lies less than [window] seconds
     * earlier and [isSame] says they match.
     */
    fun <T> split(
        items: List<T>,
        date: (T) -> Instant,
        sourceId: (T) -> String?,
        window: Double,
        isSame: (T, T) -> Boolean,
    ): Split<T> {
        val kept = mutableListOf<T>()
        val duplicates = mutableListOf<T>()
        val seenIds = mutableSetOf<String>()
        for (item in items.sortedBy(date)) {
            val id = sourceId(item)
            if (id != null && id in seenIds) {
                duplicates += item
                continue
            }
            val itemDate = date(item)
            var isDuplicate = false
            for (index in kept.indices.reversed()) {
                val previous = kept[index]
                if (itemDate.secondsSince(date(previous)) >= window) break
                if (isSame(previous, item)) {
                    isDuplicate = true
                    break
                }
            }
            if (isDuplicate) {
                duplicates += item
            } else {
                kept += item
                if (id != null) seenIds += id
            }
        }
        return Split(kept, duplicates)
    }

    fun glucose(readings: List<GlucoseReading>, window: Double): Split<GlucoseReading> =
        split(readings, { it.date }, { it.sourceId }, window) { a, b -> a.kind == b.kind && abs(a.mgdL - b.mgdL) < 1 }

    fun boluses(doses: List<InsulinDose>, window: Double): Split<InsulinDose> =
        split(doses, { it.start }, { it.sourceId }, window) { a, b -> abs(a.units - b.units) < 0.01 }

    fun carbs(entries: List<CarbIntake>, window: Double): Split<CarbIntake> =
        split(entries, { it.date }, { it.sourceId }, window) { a, b ->
            a.isFatProteinEquivalent == b.isFatProteinEquivalent && abs(a.grams - b.grams) < 0.5
        }
}
