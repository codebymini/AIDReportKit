import Foundation

/// Limits used by validation rules and the sanitizer. Glucose values in mg/dL.
public struct ValidationConfiguration: Hashable, Codable, Sendable {
    /// Readings outside `minimumPlausibleGlucose...maximumPlausibleGlucose` are errors.
    public var minimumPlausibleGlucose: Double = 20
    public var maximumPlausibleGlucose: Double = 600
    /// Rate of change above this (mg/dL per minute) between consecutive sensor readings is flagged.
    public var maximumGlucoseRateOfChange: Double = 6
    /// Sensor gaps longer than this are reported.
    public var maximumGlucoseGap: TimeInterval = 15 * 60
    /// Two records of the same kind closer than this with the same value are duplicates.
    /// Kept below 60 s so 1-minute Libre readings are not flagged.
    public var duplicateWindow: TimeInterval = 30
    /// Minimum CGM coverage before statistics are flagged as unreliable (consensus: 70%).
    public var minimumGlucoseCoverage: Double = 0.70
    /// Reports shorter than this get an info note (consensus: 14 days for GMI/TIR).
    public var recommendedSpan: TimeInterval = 14 * 86400
    public var maximumBolus: Double = 25
    public var maximumBasalRate: Double = 10
    public var maximumCarbEntry: Double = 250
    /// Basal records should cover at least this fraction of the interval.
    public var minimumBasalCoverage: Double = 0.90
    /// Records later than `now + futureTolerance` are errors (clock or time-zone problems).
    public var futureTolerance: TimeInterval = 5 * 60
    /// At most this many issues per code are kept; the rest are summarized.
    public var maximumIssuesPerCode: Int = 25

    public init() {}
}
