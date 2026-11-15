import Foundation

/// A schedule as every renderer prints it: a heading, an optional line under it, and one row per
/// entry.
public struct PrintedSchedule: Sendable {
    public enum Kind: Sendable {
        case basalRate, carbRatio, insulinSensitivity, target
    }

    public struct Row: Sendable {
        /// Seconds after local midnight.
        public var startOffset: TimeInterval
        /// "06:00"
        public var time: String
        /// The value as printed, in the report's units.
        public var value: String
        /// The value as a number, for drawing (in mg/dL for glucose).
        public var magnitude: Double
    }

    public var kind: Kind
    public var title: String
    public var note: String?
    public var rows: [Row]

    /// "0.80–1.10": the lowest and highest value as printed; `nil` when they are the same.
    public var range: String? {
        guard let low = rows.min(by: { $0.magnitude < $1.magnitude }), let high = rows.max(by: { $0.magnitude < $1.magnitude }),
              low.value != high.value
        else { return nil }
        return "\(low.value)–\(high.value)"
    }
}

extension TherapyReport {
    /// Basal rates, carb ratios and ISF, as the Insulin page prints them. Missing ones are left out.
    public func insulinSchedules(_ f: ReportFormatter) -> [PrintedSchedule] {
        guard let settings else { return [] }
        let unit = displayUnit.rawValue
        var schedules: [PrintedSchedule] = []
        if let basal = settings.basalSchedule {
            schedules.append(PrintedSchedule(
                kind: .basalRate,
                title: String(localized: "Basal rates (U/h)", bundle: .module, comment: "Settings table heading"),
                note: String(localized: "\(f.insulin(basal.dailyTotal)) per day", bundle: .module, comment: "Under the basal rates: what the schedule delivers in a day"),
                rows: basal.entries.map { .init(startOffset: $0.startOffset, time: f.timeOfDay(seconds: $0.startOffset), value: f.rate($0.ratePerHour), magnitude: $0.ratePerHour) }
            ))
        }
        if !settings.carbRatios.isEmpty {
            schedules.append(PrintedSchedule(
                kind: .carbRatio,
                title: String(localized: "Carb ratios (g/U)", bundle: .module, comment: "Settings table heading: grams of carbohydrate per unit"),
                note: nil,
                rows: settings.carbRatios.map { .init(startOffset: $0.startOffset, time: f.timeOfDay(seconds: $0.startOffset), value: f.compact($0.value), magnitude: $0.value) }
            ))
        }
        if !settings.insulinSensitivities.isEmpty {
            schedules.append(PrintedSchedule(
                kind: .insulinSensitivity,
                title: String(localized: "Insulin sensitivity (\(unit) per U)", bundle: .module,
                              comment: "Settings table heading: how far one unit lowers glucose; the argument is the glucose unit"),
                note: nil,
                rows: settings.insulinSensitivities.map { .init(startOffset: $0.startOffset, time: f.timeOfDay(seconds: $0.startOffset), value: f.glucose($0.value), magnitude: $0.value) }
            ))
        }
        return schedules
    }

    /// Glucose targets, as the Settings page prints them; `nil` without targets.
    public func targetSchedule(_ f: ReportFormatter) -> PrintedSchedule? {
        guard let targets = settings?.targets, !targets.isEmpty else { return nil }
        return PrintedSchedule(
            kind: .target,
            title: String(localized: "Glucose targets (\(displayUnit.rawValue))", bundle: .module,
                          comment: "Settings table heading: correction target ranges; the argument is the glucose unit"),
            note: nil,
            rows: targets.map { target in
                let low = f.glucose(target.low), high = f.glucose(target.high)
                return .init(startOffset: target.startOffset, time: f.timeOfDay(seconds: target.startOffset),
                             value: low == high ? low : "\(low)–\(high)", magnitude: (target.low + target.high) / 2)
            }
        )
    }

    /// Printed with every settings table.
    public static var settingsNote: String {
        String(localized: "Settings in force when the report was made. Changes during the period are not shown.", bundle: .module,
               comment: "Note under the settings tables")
    }
}

extension ReportFormatter {
    /// "06:30" for seconds after midnight.
    public func timeOfDay(seconds: TimeInterval) -> String {
        timeOfDay(minute: Int((seconds / 60).rounded()) % 1440)
    }

    /// A basal rate with two decimals, or three for 0.025 U/h steps: "0.80", "0.825".
    public func rate(_ unitsPerHour: Double) -> String {
        let three = String(format: "%.3f", unitsPerHour)
        return three.hasSuffix("0") ? String(three.dropLast()) : three
    }

    /// A number with one decimal only when it has one: "10", "7.5".
    public func compact(_ value: Double) -> String {
        let one = String(format: "%.1f", value)
        return one.hasSuffix(".0") ? String(one.dropLast(2)) : one
    }
}
