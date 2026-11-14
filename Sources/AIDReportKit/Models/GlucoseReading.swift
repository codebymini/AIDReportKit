import Foundation

/// A single glucose value, normalized to mg/dL.
public struct GlucoseReading: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// CGM reading. The only kind that counts toward glucose statistics.
        case sensor
        /// Meter or manually entered value.
        case fingerstick
        /// Calibration or display-only value.
        case calibration
    }

    public var date: Date
    public var mgdL: Double
    public var kind: Kind
    /// Stable identifier from the host (sync identifier, Core Data UUID, Nightscout `_id`).
    /// Used for de-duplication; `nil` falls back to timestamp + value matching.
    public var sourceID: String?

    public init(date: Date, mgdL: Double, kind: Kind = .sensor, sourceID: String? = nil) {
        self.date = date
        self.mgdL = mgdL
        self.kind = kind
        self.sourceID = sourceID
    }

    public init(date: Date, value: Double, unit: GlucoseUnit, kind: Kind = .sensor, sourceID: String? = nil) {
        self.init(date: date, mgdL: unit.toMgdL(value), kind: kind, sourceID: sourceID)
    }
}
