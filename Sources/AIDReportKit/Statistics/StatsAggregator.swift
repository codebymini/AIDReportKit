import Foundation

public struct TherapySummary: Hashable, Codable, Sendable {
    public var interval: DateInterval
    /// `nil` when there are no sensor readings.
    public var glucose: GlucoseStatistics?
    public var insulin: InsulinStatistics
    public var carbs: CarbStatistics
}

public struct DailySummary: Hashable, Codable, Sendable {
    /// Local midnight of the day (in the dataset's time zone).
    public var day: Date
    /// The part of that day inside the report interval (first/last days can be partial).
    public var interval: DateInterval
    public var glucose: GlucoseStatistics?
    public var insulin: InsulinStatistics
    public var carbs: CarbStatistics
}

/// Turns a (sanitized) dataset into summary, per-day and time-of-day statistics.
public struct StatsAggregator: Sendable {
    public var thresholds: GlucoseThresholds
    public var timeZone: TimeZone
    public var agpBucketMinutes: Int
    /// For programmed basal next to delivered basal; `nil` leaves it out.
    public var basalSchedule: BasalSchedule?

    public init(
        thresholds: GlucoseThresholds = .consensus,
        timeZone: TimeZone = .current,
        agpBucketMinutes: Int = 60,
        basalSchedule: BasalSchedule? = nil
    ) {
        self.thresholds = thresholds
        self.timeZone = timeZone
        self.agpBucketMinutes = agpBucketMinutes
        self.basalSchedule = basalSchedule
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    public func summary(_ dataset: TherapyDataset) -> TherapySummary {
        summary(dataset, over: dataset.interval, dataWindow: Self.dataWindow(dataset))
    }

    public func daily(_ dataset: TherapyDataset) -> [DailySummary] {
        let window = Self.dataWindow(dataset)
        return dayIntervals(covering: dataset.interval).map { day, interval in
            let summary = summary(dataset, over: interval, dataWindow: window)
            return DailySummary(day: day, interval: interval, glucose: summary.glucose, insulin: summary.insulin, carbs: summary.carbs)
        }
    }

    /// From the first to the last data point: where programmed basal is counted.
    private static func dataWindow(_ dataset: TherapyDataset) -> DateInterval? {
        dataset.dataSpan.map { DateInterval(start: $0.first, end: $0.last) }
    }

    public func dayPeriods(_ dataset: TherapyDataset) -> [DayPeriodRanges] {
        DayPeriodRanges.compute(dataset.glucose, timeZone: timeZone, thresholds: thresholds)
    }

    public func agp(_ dataset: TherapyDataset) -> AGPProfile {
        AGPProfile.compute(dataset.glucose, timeZone: timeZone, bucketMinutes: agpBucketMinutes, thresholds: thresholds)
    }

    private func summary(_ dataset: TherapyDataset, over interval: DateInterval, dataWindow: DateInterval?) -> TherapySummary {
        TherapySummary(
            interval: interval,
            glucose: GlucoseStatistics.compute(dataset.glucose, interval: interval, thresholds: thresholds),
            insulin: InsulinStatistics.compute(dataset.insulin, interval: interval, schedule: basalSchedule, within: dataWindow),
            carbs: CarbStatistics.compute(dataset.carbs, interval: interval)
        )
    }

    /// Calendar days intersecting `interval`, clipped to it.
    func dayIntervals(covering interval: DateInterval) -> [(day: Date, interval: DateInterval)] {
        let calendar = self.calendar
        var result: [(Date, DateInterval)] = []
        var dayStart = calendar.startOfDay(for: interval.start)
        while dayStart < interval.end {
            guard let next = calendar.date(byAdding: .day, value: 1, to: dayStart) else { break }
            let start = max(dayStart, interval.start)
            let end = min(next, interval.end)
            if end > start {
                result.append((dayStart, DateInterval(start: start, end: end)))
            }
            dayStart = next
        }
        return result
    }
}
