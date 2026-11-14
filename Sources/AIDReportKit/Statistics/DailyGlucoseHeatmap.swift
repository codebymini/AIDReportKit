import Foundation

/// Each day's average glucose laid out as a calendar: one cell per day, one row per week.
///
/// Renderers color a cell by `band(of:)`: where the day's average falls against the report's
/// thresholds (the 2019 consensus cut-offs by default): in range, high, very high or low.
///
/// Averages and cut-offs are compared as they are printed in the report's unit (whole mg/dL, or
/// mmol/L to one decimal), so a cell that reads "180" or "10.0" is always colored as in range.
public struct DailyGlucoseHeatmap: Hashable, Sendable {
    /// Where a day's average sits against the thresholds.
    public enum Band: String, Hashable, Sendable, CaseIterable {
        /// Below the low threshold (70 mg/dL). Rare for a whole day's average.
        case low
        /// From the low to the high threshold (70–180 mg/dL), both included.
        case inRange
        /// Above the high threshold, up to the very-high threshold (> 180–250 mg/dL).
        case high
        /// Above the very-high threshold (> 250 mg/dL).
        case veryHigh
    }

    public struct Cell: Hashable, Sendable, Identifiable {
        /// Local midnight of the day (in the report's time zone).
        public var day: Date
        public var dayOfMonth: Int
        /// `nil` when the day has no sensor readings.
        public var meanMgdL: Double?
        public var readingCount: Int
        /// Share of the day (the part inside the report period) with sensor readings.
        public var coverage: Double

        public var id: Date { day }
    }

    public struct Week: Hashable, Sendable, Identifiable {
        /// First day of the week row (may lie before the report period).
        public var start: Date
        /// Seven slots in column order; `nil` for days outside the report period.
        public var cells: [Cell?]

        public var id: Date { start }
    }

    /// Averages from days with less coverage than this are flagged as unreliable.
    public static let lowCoverageThreshold = 0.5

    public var weeks: [Week]
    /// Weekday numbers (1 = Sunday … 7 = Saturday) in column order.
    public var weekdays: [Int]
    /// The cut-offs the bands are drawn against, in mg/dL.
    public var thresholds: GlucoseThresholds
    /// The unit the report prints glucose in; bands are decided at its precision.
    public var unit: GlucoseUnit

    public init(daily: [DailySummary], thresholds: GlucoseThresholds = .consensus, unit: GlucoseUnit = .mgdL, calendar: Calendar) {
        weekdays = (0 ..< 7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
        self.thresholds = thresholds
        self.unit = unit

        let cells = daily.map { summary in
            Cell(
                day: calendar.startOfDay(for: summary.day),
                dayOfMonth: calendar.component(.day, from: summary.day),
                meanMgdL: summary.glucose?.mean,
                readingCount: summary.glucose?.readingCount ?? 0,
                coverage: summary.glucose?.coverage ?? 0
            )
        }
        let byDay = Dictionary(cells.map { ($0.day, $0) }, uniquingKeysWith: { first, _ in first })
        guard let first = cells.map(\.day).min(), let last = cells.map(\.day).max() else {
            weeks = []
            return
        }

        var rows: [Week] = []
        var weekStart = calendar.dateInterval(of: .weekOfYear, for: first)?.start ?? first
        while weekStart <= last {
            let slots = (0 ..< 7).map { offset -> Cell? in
                guard let date = calendar.date(byAdding: .day, value: offset, to: weekStart) else { return nil }
                return byDay[calendar.startOfDay(for: date)]
            }
            rows.append(Week(start: weekStart, cells: slots))
            guard let next = calendar.date(byAdding: .day, value: 7, to: weekStart) else { break }
            weekStart = next
        }
        weeks = rows
    }

    /// Every day of the report period, in date order.
    public var days: [Cell] { weeks.flatMap { $0.cells.compactMap { $0 } } }
    public var daysWithData: [Cell] { days.filter { $0.meanMgdL != nil } }

    /// The day with the lowest average (earliest wins a tie).
    public var lowest: Cell? { daysWithData.min { ($0.meanMgdL ?? 0) < ($1.meanMgdL ?? 0) } }
    /// The day with the highest average (earliest wins a tie).
    public var highest: Cell? {
        daysWithData.reduce(nil as Cell?) { best, cell in
            guard let best else { return cell }
            return (cell.meanMgdL ?? 0) > (best.meanMgdL ?? 0) ? cell : best
        }
    }

    /// The band a day's average falls in; `nil` without data.
    public func band(of cell: Cell) -> Band? {
        guard let mean = cell.meanMgdL.map(printed) else { return nil }
        if mean < printed(thresholds.low) { return .low }
        if mean <= printed(thresholds.high) { return .inRange }
        if mean <= printed(thresholds.veryHigh) { return .high }
        return .veryHigh
    }

    /// The value as the report prints it, in the report's unit.
    private func printed(_ mgdL: Double) -> Double {
        Double(unit.format(mgdL: mgdL)) ?? unit.fromMgdL(mgdL)
    }

    /// Number of days whose average falls in `band`.
    public func dayCount(in band: Band) -> Int {
        daysWithData.filter { self.band(of: $0) == band }.count
    }

    /// The bands a legend should list: in range, high and very high always; low only when a day is in it.
    public var legendBands: [Band] {
        (dayCount(in: .low) > 0 ? [.low] : []) + [.inRange, .high, .veryHigh]
    }

    /// Days whose average rests on too few readings to trust (see `lowCoverageThreshold`).
    public var lowCoverageDays: [Cell] { daysWithData.filter(isLowCoverage) }

    public func isLowCoverage(_ cell: Cell) -> Bool {
        cell.meanMgdL != nil && cell.coverage < Self.lowCoverageThreshold
    }

    /// Localized short weekday name for a weekday number (1 = Sunday … 7 = Saturday).
    public static func weekdayName(_ weekday: Int) -> String {
        switch weekday {
        case 1: return String(localized: "Sun", bundle: .module, comment: "Short weekday name: Sunday")
        case 2: return String(localized: "Mon", bundle: .module, comment: "Short weekday name: Monday")
        case 3: return String(localized: "Tue", bundle: .module, comment: "Short weekday name: Tuesday")
        case 4: return String(localized: "Wed", bundle: .module, comment: "Short weekday name: Wednesday")
        case 5: return String(localized: "Thu", bundle: .module, comment: "Short weekday name: Thursday")
        case 6: return String(localized: "Fri", bundle: .module, comment: "Short weekday name: Friday")
        default: return String(localized: "Sat", bundle: .module, comment: "Short weekday name: Saturday")
        }
    }
}

extension TherapyReport {
    /// The calendar the heatmap is laid out with: the report's time zone and the user's first weekday.
    public var heatmapCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = source.timeZone
        calendar.firstWeekday = Calendar.current.firstWeekday
        return calendar
    }

    /// Each day's average glucose as calendar weeks.
    public func dailyGlucoseHeatmap(calendar: Calendar? = nil) -> DailyGlucoseHeatmap {
        DailyGlucoseHeatmap(daily: daily, thresholds: thresholds, unit: displayUnit, calendar: calendar ?? heatmapCalendar)
    }
}
