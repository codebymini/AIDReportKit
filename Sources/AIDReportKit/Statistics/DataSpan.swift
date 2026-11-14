import Foundation

/// The first and last data point of a report.
///
/// A rolling range starts and ends mid-day, so its first and last calendar days hold less than a
/// day of data and look smaller in every per-day chart. Reports warn about that when the data
/// starts or ends more than `midnightTolerance` from midnight on the data's own clock (the
/// looper's time zone, which for a follower app is not the device's).
public struct DataSpan: Hashable, Codable, Sendable {
    public var first: Date
    public var last: Date

    /// Data starting or ending within this of midnight counts as a whole day: two missed
    /// five-minute sensor readings.
    public static let midnightTolerance: TimeInterval = 600

    public init(first: Date, last: Date) {
        self.first = first
        self.last = last
    }

    /// Whether the first data point is more than `tolerance` from midnight, on either side.
    public func isFirstDayPartial(timeZone: TimeZone, tolerance: TimeInterval = midnightTolerance) -> Bool {
        Self.distanceToMidnight(first, timeZone: timeZone) > tolerance
    }

    /// Whether the last data point is more than `tolerance` from midnight, on either side.
    public func isLastDayPartial(timeZone: TimeZone, tolerance: TimeInterval = midnightTolerance) -> Bool {
        Self.distanceToMidnight(last, timeZone: timeZone) > tolerance
    }

    /// Seconds to the nearest midnight, before or after `date`, on the clock of `timeZone`.
    public static func distanceToMidnight(_ date: Date, timeZone: TimeZone) -> TimeInterval {
        let calendar = calendar(timeZone)
        let dayStart = calendar.startOfDay(for: date)
        let sinceMidnight = date.timeIntervalSince(dayStart)
        guard let nextMidnight = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return sinceMidnight }
        return min(sinceMidnight, nextMidnight.timeIntervalSince(date))
    }

    private static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}

extension TherapyDataset {
    /// The first and last data point of any kind inside the interval; `nil` when there is none.
    public var dataSpan: DataSpan? {
        let doses = insulin.flatMap { [max($0.start, interval.start), min($0.end, interval.end)] }
        let dates = (glucose.map(\.date) + carbs.map(\.date) + doses).filter { $0 >= interval.start && $0 <= interval.end }
        guard let first = dates.min(), let last = dates.max() else { return nil }
        return DataSpan(first: first, last: last)
    }
}

extension TherapyReport {
    /// The calendar days are counted in: Gregorian, in the data's time zone.
    public var dayCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = source.timeZone
        return calendar
    }

    /// Whether the first calendar day of the report holds only part of a day of data.
    public var isFirstDayPartial: Bool { dataSpan?.isFirstDayPartial(timeZone: source.timeZone) ?? false }
    /// Whether the last calendar day of the report holds only part of a day of data.
    public var isLastDayPartial: Bool { dataSpan?.isLastDayPartial(timeZone: source.timeZone) ?? false }
}
