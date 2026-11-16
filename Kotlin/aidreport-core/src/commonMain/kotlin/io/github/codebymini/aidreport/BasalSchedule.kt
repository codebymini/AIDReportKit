package io.github.codebymini.aidreport

import kotlinx.datetime.TimeZone
import kotlinx.serialization.Serializable
import kotlin.time.Instant

/**
 * A repeating 24-hour basal profile. Used to fill time not covered by temp basals, because
 * Trio's pump history and Nightscout only record deviations from the schedule.
 *
 * Create one with `BasalSchedule(entries, timeZone)`, which returns `null` for an empty schedule
 * and treats the earliest entry as starting at midnight.
 */
@ConsistentCopyVisibility
@Serializable
public data class BasalSchedule private constructor(
    val entries: List<Entry>,
    val timeZoneIdentifier: String,
) {
    @Serializable
    public data class Entry(
        /** Seconds after local midnight. */
        val startOffset: Double,
        val ratePerHour: Double,
    )

    val timeZone: TimeZone get() = zoneNamed(timeZoneIdentifier)

    public fun rate(date: Instant): Double {
        val offset = date.secondsSince(timeZone.startOfDay(date))
        return entries.lastOrNull { it.startOffset <= offset }?.ratePerHour ?: entries[0].ratePerHour
    }

    /** Total scheduled units per day. */
    val dailyTotal: Double
        get() = entries.zip(entries.drop(1).map { it.startOffset } + 86400.0)
            .fold(0.0) { total, (entry, next) -> total + entry.ratePerHour * (next - entry.startOffset) / 3600 }

    /**
     * Scheduled-basal doses covering [interval], split at schedule boundaries and midnight.
     *
     * Offsets are wall-clock seconds from midnight, so on DST transition days one segment can be
     * off by the shift. That is acceptable for daily totals.
     */
    public fun doses(interval: DateInterval): List<InsulinDose> {
        val zone = timeZone
        val result = mutableListOf<InsulinDose>()
        var cursor = interval.start
        while (cursor < interval.end) {
            val dayStart = zone.startOfDay(cursor)
            val offset = cursor.secondsSince(dayStart)
            val index = entries.indexOfLast { it.startOffset <= offset }.coerceAtLeast(0)
            val nextBoundary = if (index + 1 < entries.size) {
                dayStart.plusSeconds(entries[index + 1].startOffset)
            } else {
                zone.addingDays(1, dayStart)
            }
            val segmentEnd = minOf(nextBoundary, interval.end)
            if (segmentEnd <= cursor) break
            result += InsulinDose.basal(InsulinDose.Kind.BASAL, cursor, segmentEnd, entries[index].ratePerHour, isAutomatic = false)
            cursor = segmentEnd
        }
        return result
    }

    public companion object {
        /** `null` for an empty schedule. The earliest entry is treated as starting at midnight. */
        public operator fun invoke(entries: List<Entry>, timeZone: TimeZone = TimeZone.currentSystemDefault()): BasalSchedule? {
            val sorted = entries.sortedBy { it.startOffset }.toMutableList()
            if (sorted.isEmpty()) return null
            sorted[0] = sorted[0].copy(startOffset = 0.0)
            return BasalSchedule(sorted, timeZone.id)
        }
    }
}

/** Helpers that turn the different ways hosts record basal into one consistent timeline. */
public object BasalTimeline {
    /**
     * Ends each basal-like dose where the next one starts.
     *
     * Trio's pump history and Nightscout record a new temp basal as replacing the running one
     * without closing it, so without this a 30-minute temp set every 5 minutes is counted 6×.
     */
    public fun truncatingOverlaps(doses: List<InsulinDose>): List<InsulinDose> {
        val boluses = doses.filter { !it.isBasalLike }
        val suspends = doses.filter { it.kind == InsulinDose.Kind.SUSPEND && it.duration > 0 }
        var basal = doses.filter { it.isBasalLike && it.kind != InsulinDose.Kind.SUSPEND }.sortedBy { it.start }.toMutableList()
        for (index in 0 until basal.size - 1) {
            if (basal[index + 1].start < basal[index].end) {
                basal[index] = basal[index].ending(basal[index + 1].start)
            }
        }
        basal.removeAll { it.duration <= 0 }

        // A suspension wins over any basal recorded while it lasts: nothing was delivered.
        val suspended = coveredIntervals(suspends)
        if (suspended.isNotEmpty()) {
            basal = basal.flatMap { dose ->
                gaps(DateInterval(dose.start, dose.end), suspended).mapNotNull { dose.clamped(it) }
            }.toMutableList()
        }
        return (boluses + basal + suspends).sortedBy { it.start }
    }

    /** Merged intervals covered by basal-like doses (suspends count as covered). */
    public fun coveredIntervals(doses: List<InsulinDose>): List<DateInterval> {
        val spans = doses.filter { it.isBasalLike && it.duration > 0 }
            .map { DateInterval(it.start, it.end) }
            .sortedBy { it.start }
        val merged = mutableListOf<DateInterval>()
        for (span in spans) {
            val last = merged.lastOrNull()
            if (last != null && span.start <= last.end) {
                merged[merged.size - 1] = DateInterval(last.start, maxOf(last.end, span.end))
            } else {
                merged += span
            }
        }
        return merged
    }

    /** Parts of [interval] not covered by [covered] (which must be sorted and non-overlapping). */
    public fun gaps(interval: DateInterval, covered: List<DateInterval>, minimumDuration: Double = 0.0): List<DateInterval> {
        val gaps = mutableListOf<DateInterval>()
        var cursor = interval.start
        for (span in covered) {
            if (span.end <= interval.start || span.start >= interval.end) continue
            if (span.start > cursor) gaps += DateInterval(cursor, span.start)
            cursor = maxOf(cursor, span.end)
        }
        if (cursor < interval.end) gaps += DateInterval(cursor, interval.end)
        return gaps.filter { it.duration > minimumDuration }
    }

    /** Fraction of [interval] covered by basal-like doses. */
    public fun coverage(doses: List<InsulinDose>, interval: DateInterval): Double {
        if (interval.duration <= 0) return 0.0
        val uncovered = gaps(interval, coveredIntervals(doses)).fold(0.0) { total, gap -> total + gap.duration }
        return maxOf(0.0, 1 - uncovered / interval.duration)
    }

    /** Adds scheduled basal wherever no basal-like dose covers [interval]. */
    public fun fillingGaps(
        doses: List<InsulinDose>,
        interval: DateInterval,
        schedule: BasalSchedule,
        minimumGap: Double = 60.0,
    ): List<InsulinDose> {
        val fill = gaps(interval, coveredIntervals(doses), minimumGap).flatMap { schedule.doses(it) }
        return (doses + fill).sortedBy { it.start }
    }

    /**
     * Converts a step series of `(date, rate)` points into basal doses: each rate holds until the
     * next point. Matches how LoopFollow stores its basal graph (start/end dot pairs).
     */
    public fun doses(
        stepSeries: List<Pair<Instant, Double>>,
        kind: InsulinDose.Kind = InsulinDose.Kind.TEMP_BASAL,
        isAutomatic: Boolean = true,
    ): List<InsulinDose> {
        val sorted = stepSeries.sortedBy { it.first }
        return sorted.zipWithNext().mapNotNull { (current, next) ->
            if (next.first <= current.first) {
                null
            } else {
                InsulinDose.basal(kind, current.first, next.first, current.second, isAutomatic)
            }
        }
    }
}
