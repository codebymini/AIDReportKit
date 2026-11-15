import Foundation

/// The therapy settings in force when the report was made, as the app supplies them.
///
/// Schedules repeat every day: each entry holds from its time of day until the next one, on the
/// looper's clock. Glucose values are mg/dL (the report prints them in its display unit); insulin
/// is in units. None of the apps keep a history of setting changes, so a report shows today's
/// settings next to statistics from the whole period.
public struct TherapySettingsSnapshot: Hashable, Codable, Sendable {
    /// A value from a time of day until the next entry.
    public struct Entry: Hashable, Codable, Sendable {
        /// Seconds after local midnight.
        public var startOffset: TimeInterval
        public var value: Double

        public init(startOffset: TimeInterval, value: Double) {
            self.startOffset = startOffset
            self.value = value
        }
    }

    /// A glucose target range from a time of day until the next entry, in mg/dL.
    public struct TargetRange: Hashable, Codable, Sendable {
        /// Seconds after local midnight.
        public var startOffset: TimeInterval
        public var low: Double
        public var high: Double

        public init(startOffset: TimeInterval, low: Double, high: Double) {
            self.startOffset = startOffset
            self.low = low
            self.high = high
        }
    }

    /// A titled list of other settings ("Limits", "Insulin model", "Algorithm"), formatted by the
    /// app in its own words and units.
    public struct Group: Hashable, Codable, Sendable {
        public var title: String
        public var items: [ReportMetadata.Item]

        public init(_ title: String, _ items: [ReportMetadata.Item]) {
            self.title = title
            self.items = items
        }
    }

    /// U/h. A report fills it from `ReportOptions.basalSchedule` when it is not set here.
    public var basalSchedule: BasalSchedule?
    /// Grams of carbohydrate one unit covers.
    public var carbRatios: [Entry]
    /// How far one unit lowers glucose, in mg/dL.
    public var insulinSensitivities: [Entry]
    /// Correction target ranges, in mg/dL.
    public var targets: [TargetRange]
    /// Everything else, for the Settings page.
    public var groups: [Group]

    public init(
        basalSchedule: BasalSchedule? = nil,
        carbRatios: [Entry] = [],
        insulinSensitivities: [Entry] = [],
        targets: [TargetRange] = [],
        groups: [Group] = []
    ) {
        self.basalSchedule = basalSchedule
        self.carbRatios = carbRatios.sorted { $0.startOffset < $1.startOffset }
        self.insulinSensitivities = insulinSensitivities.sorted { $0.startOffset < $1.startOffset }
        self.targets = targets.sorted { $0.startOffset < $1.startOffset }
        self.groups = groups.filter { !$0.items.isEmpty }
    }

    public var isEmpty: Bool {
        basalSchedule == nil && carbRatios.isEmpty && insulinSensitivities.isEmpty && targets.isEmpty && groups.isEmpty
    }
}
