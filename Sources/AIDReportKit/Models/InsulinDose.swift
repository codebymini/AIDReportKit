import Foundation

/// Insulin delivered over `[start, end]`. Boluses usually have `start == end`.
///
/// `units` is always the absolute amount delivered (never "net of scheduled basal"),
/// so summing `units` over an interval gives total insulin.
public struct InsulinDose: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case bolus
        /// Scheduled basal from the profile.
        case basal
        /// Temporary basal set by the loop or the user.
        case tempBasal
        /// Delivery suspended. `units` is 0.
        case suspend
    }

    public var kind: Kind
    public var start: Date
    public var end: Date
    public var units: Double
    /// Issued by the algorithm (SMB, automatic bolus, loop-set temp basal) rather than the user.
    public var isAutomatic: Bool
    /// Logged but not delivered by the pump (pen, inhaled insulin, "External Insulin").
    public var isExternal: Bool
    public var sourceID: String?

    public init(
        kind: Kind,
        start: Date,
        end: Date,
        units: Double,
        isAutomatic: Bool = false,
        isExternal: Bool = false,
        sourceID: String? = nil
    ) {
        self.kind = kind
        self.start = start
        self.end = end
        self.units = units
        self.isAutomatic = isAutomatic
        self.isExternal = isExternal
        self.sourceID = sourceID
    }

    public static func bolus(
        at date: Date,
        units: Double,
        isAutomatic: Bool = false,
        isExternal: Bool = false,
        sourceID: String? = nil
    ) -> InsulinDose {
        InsulinDose(kind: .bolus, start: date, end: date, units: units, isAutomatic: isAutomatic, isExternal: isExternal, sourceID: sourceID)
    }

    /// A basal-like dose from a rate; `units` = rate × hours.
    public static func basal(
        _ kind: Kind = .tempBasal,
        start: Date,
        end: Date,
        ratePerHour: Double,
        isAutomatic: Bool = true,
        sourceID: String? = nil
    ) -> InsulinDose {
        let hours = max(0, end.timeIntervalSince(start)) / 3600
        return InsulinDose(kind: kind, start: start, end: end, units: ratePerHour * hours, isAutomatic: isAutomatic, sourceID: sourceID)
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    public var isBasalLike: Bool { kind != .bolus }

    /// Units per hour, or `nil` for zero-length doses.
    public var ratePerHour: Double? {
        duration > 0 ? units / (duration / 3600) : nil
    }

    /// The part of this dose inside `interval` (half-open), with units prorated linearly.
    /// Boluses and zero-length doses are kept whole if they start inside the interval.
    public func clamped(to interval: DateInterval) -> InsulinDose? {
        if kind == .bolus || duration <= 0 {
            return interval.containsHalfOpen(start) ? self : nil
        }
        let newStart = max(start, interval.start)
        let newEnd = min(end, interval.end)
        guard newEnd > newStart else { return nil }
        var copy = self
        copy.units = units * newEnd.timeIntervalSince(newStart) / duration
        copy.start = newStart
        copy.end = newEnd
        return copy
    }

    /// This dose cut short at `date`, units prorated. No-op for boluses or if `date` is past the end.
    public func ending(at date: Date) -> InsulinDose {
        guard isBasalLike, date < end else { return self }
        var copy = self
        let newEnd = max(start, date)
        copy.units = duration > 0 ? units * newEnd.timeIntervalSince(start) / duration : 0
        copy.end = newEnd
        return copy
    }
}

extension DateInterval {
    /// `start <= date < end`. Foundation's `contains` includes `end`, which double-counts at day boundaries.
    public func containsHalfOpen(_ date: Date) -> Bool {
        date >= start && date < end
    }
}
