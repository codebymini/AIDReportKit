import Foundation

/// Helpers that turn the different ways hosts record basal into one consistent timeline.
public enum BasalTimeline {
    /// Ends each basal-like dose where the next one starts.
    ///
    /// Trio's pump history and Nightscout record a new temp basal as replacing the running one
    /// without closing it, so without this a 30-minute temp set every 5 minutes is counted 6×.
    public static func truncatingOverlaps(_ doses: [InsulinDose]) -> [InsulinDose] {
        let boluses = doses.filter { !$0.isBasalLike }
        let suspends = doses.filter { $0.kind == .suspend && $0.duration > 0 }
        var basal = doses.filter { $0.isBasalLike && $0.kind != .suspend }.sorted { $0.start < $1.start }
        for index in basal.indices.dropLast() where basal[index + 1].start < basal[index].end {
            basal[index] = basal[index].ending(at: basal[index + 1].start)
        }
        basal.removeAll { $0.duration <= 0 }

        // A suspension wins over any basal recorded while it lasts: nothing was delivered.
        let suspended = coveredIntervals(suspends)
        if !suspended.isEmpty {
            basal = basal.flatMap { dose in
                gaps(in: DateInterval(start: dose.start, end: dose.end), covered: suspended).compactMap { dose.clamped(to: $0) }
            }
        }
        return (boluses + basal + suspends).sorted { $0.start < $1.start }
    }

    /// Merged intervals covered by basal-like doses (suspends count as covered).
    public static func coveredIntervals(_ doses: [InsulinDose]) -> [DateInterval] {
        let spans = doses.filter { $0.isBasalLike && $0.duration > 0 }
            .map { DateInterval(start: $0.start, end: $0.end) }
            .sorted { $0.start < $1.start }
        var merged: [DateInterval] = []
        for span in spans {
            if let last = merged.last, span.start <= last.end {
                merged[merged.count - 1] = DateInterval(start: last.start, end: max(last.end, span.end))
            } else {
                merged.append(span)
            }
        }
        return merged
    }

    /// Parts of `interval` not covered by `covered` (which must be sorted and non-overlapping).
    public static func gaps(in interval: DateInterval, covered: [DateInterval], minimumDuration: TimeInterval = 0) -> [DateInterval] {
        var gaps: [DateInterval] = []
        var cursor = interval.start
        for span in covered where span.end > interval.start && span.start < interval.end {
            if span.start > cursor {
                gaps.append(DateInterval(start: cursor, end: span.start))
            }
            cursor = max(cursor, span.end)
        }
        if cursor < interval.end {
            gaps.append(DateInterval(start: cursor, end: interval.end))
        }
        return gaps.filter { $0.duration > minimumDuration }
    }

    /// Fraction of `interval` covered by basal-like doses.
    public static func coverage(_ doses: [InsulinDose], in interval: DateInterval) -> Double {
        guard interval.duration > 0 else { return 0 }
        let uncovered = gaps(in: interval, covered: coveredIntervals(doses)).reduce(0) { $0 + $1.duration }
        return max(0, 1 - uncovered / interval.duration)
    }

    /// Adds scheduled basal wherever no basal-like dose covers `interval`.
    public static func fillingGaps(
        _ doses: [InsulinDose],
        in interval: DateInterval,
        with schedule: BasalSchedule,
        minimumGap: TimeInterval = 60
    ) -> [InsulinDose] {
        let fill = gaps(in: interval, covered: coveredIntervals(doses), minimumDuration: minimumGap)
            .flatMap { schedule.doses(in: $0) }
        return (doses + fill).sorted { $0.start < $1.start }
    }

    /// Converts a step series of `(date, rate)` points into basal doses: each rate holds until
    /// the next point. Matches how LoopFollow stores its basal graph (start/end dot pairs).
    public static func doses(
        fromStepSeries points: [(date: Date, ratePerHour: Double)],
        kind: InsulinDose.Kind = .tempBasal,
        isAutomatic: Bool = true
    ) -> [InsulinDose] {
        let sorted = points.sorted { $0.date < $1.date }
        return zip(sorted, sorted.dropFirst()).compactMap { current, next in
            guard next.date > current.date else { return nil }
            return .basal(kind, start: current.date, end: next.date, ratePerHour: current.ratePerHour, isAutomatic: isAutomatic)
        }
    }
}
