import Foundation

/// Consistent number/date formatting for every renderer (Markdown, CSV, PDF).
/// Dates use the report's time zone; glucose uses the report's display unit.
public struct ReportFormatter: Sendable {
    public var unit: GlucoseUnit
    public var timeZone: TimeZone

    public init(unit: GlucoseUnit, timeZone: TimeZone) {
        self.unit = unit
        self.timeZone = timeZone
    }

    public init(report: TherapyReport) {
        self.init(unit: report.displayUnit, timeZone: report.source.timeZone)
    }

    public func glucose(_ mgdL: Double, withUnit: Bool = false) -> String {
        unit.format(mgdL: mgdL, includeUnit: withUnit)
    }

    public func percent(_ fraction: Double, decimals: Int = 1) -> String {
        String(format: "%.\(decimals)f%%", fraction * 100)
    }

    public func insulin(_ units: Double) -> String {
        String(format: "%.1f U", units)
    }

    public func grams(_ grams: Double) -> String {
        String(format: "%.0f g", grams)
    }

    public func number(_ value: Double, decimals: Int = 1) -> String {
        String(format: "%.\(decimals)f", value)
    }

    public func day(_ date: Date) -> String {
        format(date, "yyyy-MM-dd")
    }

    /// Month and day only, for tight spaces such as calendar rows.
    public func shortDay(_ date: Date) -> String {
        format(date, "MM-dd")
    }

    public func dateTime(_ date: Date) -> String {
        format(date, "yyyy-MM-dd HH:mm")
    }

    /// Short name of the time zone every date and time in the report is in, e.g. "GMT+1".
    public func timeZoneLabel(at date: Date) -> String {
        let seconds = timeZone.secondsFromGMT(for: date)
        guard seconds != 0 else { return "GMT" }
        let minutes = abs(seconds) / 60
        let sign = seconds < 0 ? "-" : "+"
        return minutes % 60 == 0 ? "GMT\(sign)\(minutes / 60)" : String(format: "GMT%@%d:%02d", sign, minutes / 60, minutes % 60)
    }

    /// Date and time followed by the time zone, e.g. "2026-11-14 23:33 (GMT+1)".
    public func dateTimeWithZone(_ date: Date) -> String {
        "\(dateTime(date)) (\(timeZoneLabel(at: date)))"
    }

    public func period(_ interval: DateInterval) -> String {
        "\(dateTime(interval.start)) – \(dateTime(interval.end))"
    }

    public func timeOfDay(minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }

    public func duration(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int((seconds / 60).rounded())
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return hours > 0
            ? String(localized: "\(hours) h \(minutes) min", bundle: .module, comment: "Duration in hours and minutes")
            : String(localized: "\(minutes) min", bundle: .module, comment: "Duration in minutes")
    }

    /// Labels for the time-in-range bands in the display unit, e.g. "In range (70–180)".
    public func bandLabels(_ t: GlucoseThresholds) -> (veryLow: String, low: String, inRange: String, high: String, veryHigh: String, tight: String) {
        let g = { (value: Double) in self.glucose(value) }
        return (
            String(localized: "Very low (<\(g(t.veryLow)))", bundle: .module, comment: "Glucose band below the very-low threshold; the argument is that threshold"),
            String(localized: "Low (\(g(t.veryLow))–<\(g(t.low)))", bundle: .module, comment: "Glucose band between the very-low and low thresholds"),
            String(localized: "In range (\(g(t.low))–\(g(t.high)))", bundle: .module, comment: "Glucose band between the low and high thresholds"),
            String(localized: "High (>\(g(t.high))–\(g(t.veryHigh)))", bundle: .module, comment: "Glucose band between the high and very-high thresholds"),
            String(localized: "Very high (>\(g(t.veryHigh)))", bundle: .module, comment: "Glucose band above the very-high threshold"),
            String(localized: "Tight range (\(g(t.low))–\(g(t.tightHigh)))", bundle: .module, comment: "Glucose band for time in tight range (TITR)")
        )
    }

    private func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
