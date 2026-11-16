package io.github.codebymini.aidreport

import kotlinx.datetime.TimeZone
import kotlinx.datetime.isoDayNumber
import kotlinx.datetime.toLocalDateTime
import kotlin.time.Instant

/**
 * Each day's average glucose laid out as a calendar: one cell per day, one row per week.
 *
 * Renderers color a cell by [band]: where the day's average falls against the report's thresholds
 * (the 2019 consensus cut-offs by default): in range, high, very high or low.
 *
 * Averages and cut-offs are compared as they are printed in the report's unit (whole mg/dL, or
 * mmol/L to one decimal), so a cell that reads "180" or "10.0" is always colored as in range.
 *
 * @param firstWeekday The weekday the rows start on, 1 = Sunday … 7 = Saturday (Swift's numbering).
 */
public class DailyGlucoseHeatmap(
    daily: List<DailySummary>,
    /** The cut-offs the bands are drawn against, in mg/dL. */
    public val thresholds: GlucoseThresholds = GlucoseThresholds.consensus,
    /** The unit the report prints glucose in; bands are decided at its precision. */
    public val unit: GlucoseUnit = GlucoseUnit.MGDL,
    timeZone: TimeZone,
    firstWeekday: Int = 2,
) {
    /** Where a day's average sits against the thresholds. */
    public enum class Band {
        /** Below the low threshold (70 mg/dL). Rare for a whole day's average. */
        LOW,

        /** From the low to the high threshold (70–180 mg/dL), both included. */
        IN_RANGE,

        /** Above the high threshold, up to the very-high threshold (> 180–250 mg/dL). */
        HIGH,

        /** Above the very-high threshold (> 250 mg/dL). */
        VERY_HIGH,
    }

    public data class Cell(
        /** Local midnight of the day (in the report's time zone). */
        val day: Instant,
        val dayOfMonth: Int,
        /** `null` when the day has no sensor readings. */
        val meanMgdL: Double?,
        val readingCount: Int,
        /** Share of the day (the part inside the report period) with sensor readings. */
        val coverage: Double,
    )

    public data class Week(
        /** First day of the week row (may lie before the report period). */
        val start: Instant,
        /** Seven slots in column order; `null` for days outside the report period. */
        val cells: List<Cell?>,
    )

    /** Weekday numbers (1 = Sunday … 7 = Saturday) in column order. */
    public val weekdays: List<Int> = (0 until 7).map { (firstWeekday - 1 + it) % 7 + 1 }

    public val weeks: List<Week>

    init {
        val cells = daily.map { summary ->
            Cell(
                day = timeZone.startOfDay(summary.day),
                dayOfMonth = summary.day.toLocalDateTime(timeZone).day,
                meanMgdL = summary.glucose?.mean,
                readingCount = summary.glucose?.readingCount ?: 0,
                coverage = summary.glucose?.coverage ?: 0.0,
            )
        }
        val byDay = linkedMapOf<Instant, Cell>()
        for (cell in cells) if (cell.day !in byDay) byDay[cell.day] = cell
        val first = cells.minOfOrNull { it.day }
        val last = cells.maxOfOrNull { it.day }
        weeks = if (first == null || last == null) {
            emptyList()
        } else {
            val weekday = first.toLocalDateTime(timeZone).date.dayOfWeek.isoDayNumber % 7 + 1
            var weekStart = timeZone.addingDays(-((weekday - firstWeekday + 7) % 7), first)
            val rows = mutableListOf<Week>()
            while (weekStart <= last) {
                val start = weekStart
                rows += Week(start, (0 until 7).map { offset -> byDay[timeZone.startOfDay(timeZone.addingDays(offset, start))] })
                weekStart = timeZone.addingDays(7, weekStart)
            }
            rows
        }
    }

    /** Every day of the report period, in date order. */
    public val days: List<Cell> get() = weeks.flatMap { week -> week.cells.filterNotNull() }
    public val daysWithData: List<Cell> get() = days.filter { it.meanMgdL != null }

    /** The day with the lowest average (earliest wins a tie). */
    public val lowest: Cell? get() = daysWithData.minByOrNull { it.meanMgdL ?: 0.0 }

    /** The day with the highest average (earliest wins a tie). */
    public val highest: Cell? get() = daysWithData.maxByOrNull { it.meanMgdL ?: 0.0 }

    /** The band a day's average falls in; `null` without data. */
    public fun band(cell: Cell): Band? {
        val mean = cell.meanMgdL?.let(::printed) ?: return null
        return when {
            mean < printed(thresholds.low) -> Band.LOW
            mean <= printed(thresholds.high) -> Band.IN_RANGE
            mean <= printed(thresholds.veryHigh) -> Band.HIGH
            else -> Band.VERY_HIGH
        }
    }

    /** The value as the report prints it, in the report's unit. */
    private fun printed(mgdL: Double): Double = unit.format(mgdL).toDoubleOrNull() ?: unit.fromMgdL(mgdL)

    /** Number of days whose average falls in [band]. */
    public fun dayCount(band: Band): Int = daysWithData.count { band(it) == band }

    /** The bands a legend should list: in range, high and very high always; low only when a day is in it. */
    public val legendBands: List<Band>
        get() = (if (dayCount(Band.LOW) > 0) listOf(Band.LOW) else emptyList()) + listOf(Band.IN_RANGE, Band.HIGH, Band.VERY_HIGH)

    /** Days whose average rests on too few readings to trust (see [LOW_COVERAGE_THRESHOLD]). */
    public val lowCoverageDays: List<Cell> get() = daysWithData.filter(::isLowCoverage)

    public fun isLowCoverage(cell: Cell): Boolean = cell.meanMgdL != null && cell.coverage < LOW_COVERAGE_THRESHOLD

    public companion object {
        /** Averages from days with less coverage than this are flagged as unreliable. */
        public const val LOW_COVERAGE_THRESHOLD: Double = 0.5

        /** Short weekday name for a weekday number (1 = Sunday … 7 = Saturday). */
        public fun weekdayName(weekday: Int): String = when (weekday) {
            1 -> "Sun"
            2 -> "Mon"
            3 -> "Tue"
            4 -> "Wed"
            5 -> "Thu"
            6 -> "Fri"
            else -> "Sat"
        }
    }
}

/** Each day's average glucose as calendar weeks, rows starting on [firstWeekday] (1 = Sunday … 7 = Saturday). */
public fun TherapyReport.dailyGlucoseHeatmap(firstWeekday: Int = 2): DailyGlucoseHeatmap =
    DailyGlucoseHeatmap(daily, thresholds, displayUnit, source.timeZone, firstWeekday)
