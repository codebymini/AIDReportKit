import Foundation

/// A repeating 24-hour basal profile. Used to fill time not covered by temp basals,
/// because Trio's pump history and Nightscout only record deviations from the schedule.
public struct BasalSchedule: Hashable, Codable, Sendable {
    public struct Entry: Hashable, Codable, Sendable {
        /// Seconds after local midnight.
        public var startOffset: TimeInterval
        public var ratePerHour: Double

        public init(startOffset: TimeInterval, ratePerHour: Double) {
            self.startOffset = startOffset
            self.ratePerHour = ratePerHour
        }
    }

    public private(set) var entries: [Entry]
    public var timeZoneIdentifier: String

    /// Returns `nil` for an empty schedule. The earliest entry is treated as starting at midnight.
    public init?(entries: [Entry], timeZone: TimeZone = .current) {
        var sorted = entries.sorted { $0.startOffset < $1.startOffset }
        guard !sorted.isEmpty else { return nil }
        sorted[0].startOffset = 0
        self.entries = sorted
        self.timeZoneIdentifier = timeZone.identifier
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        return calendar
    }

    public func rate(at date: Date) -> Double {
        let offset = date.timeIntervalSince(calendar.startOfDay(for: date))
        return entries.last { $0.startOffset <= offset }?.ratePerHour ?? entries[0].ratePerHour
    }

    /// Total scheduled units per day.
    public var dailyTotal: Double {
        zip(entries, entries.dropFirst().map(\.startOffset) + [86400])
            .reduce(0) { $0 + $1.0.ratePerHour * ($1.1 - $1.0.startOffset) / 3600 }
    }

    /// Scheduled-basal doses covering `interval`, split at schedule boundaries and midnight.
    ///
    /// Offsets are wall-clock seconds from midnight, so on DST transition days one segment
    /// can be off by the shift. That is acceptable for daily totals.
    public func doses(in interval: DateInterval) -> [InsulinDose] {
        let calendar = self.calendar
        var result: [InsulinDose] = []
        var cursor = interval.start
        while cursor < interval.end {
            let dayStart = calendar.startOfDay(for: cursor)
            let offset = cursor.timeIntervalSince(dayStart)
            let index = entries.lastIndex { $0.startOffset <= offset } ?? 0
            let nextBoundary: Date
            if index + 1 < entries.count {
                nextBoundary = dayStart.addingTimeInterval(entries[index + 1].startOffset)
            } else {
                nextBoundary = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? interval.end
            }
            let segmentEnd = min(nextBoundary, interval.end)
            guard segmentEnd > cursor else { break }
            result.append(.basal(.basal, start: cursor, end: segmentEnd, ratePerHour: entries[index].ratePerHour, isAutomatic: false))
            cursor = segmentEnd
        }
        return result
    }
}
