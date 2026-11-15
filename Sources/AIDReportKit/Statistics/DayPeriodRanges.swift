import Foundation

/// Time in ranges for one part of the day, all days overlaid, on the report's clock.
public struct DayPeriodRanges: Hashable, Codable, Sendable {
    /// Night, morning, afternoon and evening: the same six-hour parts of the day as LoopFollow's
    /// time-in-range statistics.
    public enum Period: String, Hashable, Codable, Sendable, CaseIterable {
        case night, morning, afternoon, evening

        /// Hours of the day, end excluded: 0–6, 6–12, 12–18, 18–24.
        public var hours: Range<Int> {
            switch self {
            case .night: return 0 ..< 6
            case .morning: return 6 ..< 12
            case .afternoon: return 12 ..< 18
            case .evening: return 18 ..< 24
            }
        }

        public var title: String {
            switch self {
            case .night: return String(localized: "Night", bundle: .module, comment: "Part of the day: 00–06")
            case .morning: return String(localized: "Morning", bundle: .module, comment: "Part of the day: 06–12")
            case .afternoon: return String(localized: "Afternoon", bundle: .module, comment: "Part of the day: 12–18")
            case .evening: return String(localized: "Evening", bundle: .module, comment: "Part of the day: 18–24")
            }
        }

        /// The hours as printed, e.g. "06–12".
        public var hoursText: String {
            String(format: "%02d–%02d", hours.lowerBound, hours.upperBound)
        }

        public init(hour: Int) {
            self = Self.allCases.first { $0.hours.contains(hour) } ?? .evening
        }
    }

    public var period: Period
    public var readingCount: Int
    /// `nil` when the period has no sensor readings.
    public var timeInRanges: TimeInRanges?

    /// One entry per period, in order, from sensor readings only.
    public static func compute(
        _ readings: [GlucoseReading],
        timeZone: TimeZone,
        thresholds: GlucoseThresholds = .consensus
    ) -> [DayPeriodRanges] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var values: [Period: [Double]] = [:]
        for reading in readings where reading.kind == .sensor {
            values[Period(hour: calendar.component(.hour, from: reading.date)), default: []].append(reading.mgdL)
        }
        return Period.allCases.map { period in
            let periodValues = values[period] ?? []
            return DayPeriodRanges(
                period: period,
                readingCount: periodValues.count,
                timeInRanges: periodValues.isEmpty ? nil : TimeInRanges(values: periodValues, thresholds: thresholds)
            )
        }
    }
}
