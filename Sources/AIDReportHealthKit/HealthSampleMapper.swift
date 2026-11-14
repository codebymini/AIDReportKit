import AIDReportKit
import Foundation

/// A HealthKit quantity sample reduced to the fields AIDReportKit uses, so mapping can be tested
/// without a health store (and on platforms without HealthKit).
public struct HealthSample: Hashable, Sendable {
    public enum InsulinDeliveryReason: Int, Sendable {
        case basal = 1
        case bolus = 2
    }

    public var start: Date
    public var end: Date
    /// Already converted: mg/dL for glucose, IU for insulin, grams for carbs.
    public var value: Double
    public var uuid: UUID
    public var sourceBundleID: String?
    public var syncIdentifier: String?
    public var wasUserEntered: Bool
    public var isDisplayOnly: Bool
    public var insulinDeliveryReason: InsulinDeliveryReason?
    /// LoopKit `MetadataKeyAutomaticallyIssued`.
    public var isAutomatic: Bool?
    /// LoopKit `MetadataKeyManuallyEntered` (logged dose, not pump-delivered).
    public var isManuallyEntered: Bool
    /// LoopKit `MetadataKeyIsSuspend`.
    public var isSuspend: Bool
    public var absorptionTime: TimeInterval?

    public init(
        start: Date,
        end: Date? = nil,
        value: Double,
        uuid: UUID = UUID(),
        sourceBundleID: String? = nil,
        syncIdentifier: String? = nil,
        wasUserEntered: Bool = false,
        isDisplayOnly: Bool = false,
        insulinDeliveryReason: InsulinDeliveryReason? = nil,
        isAutomatic: Bool? = nil,
        isManuallyEntered: Bool = false,
        isSuspend: Bool = false,
        absorptionTime: TimeInterval? = nil
    ) {
        self.start = start
        self.end = end ?? start
        self.value = value
        self.uuid = uuid
        self.sourceBundleID = sourceBundleID
        self.syncIdentifier = syncIdentifier
        self.wasUserEntered = wasUserEntered
        self.isDisplayOnly = isDisplayOnly
        self.insulinDeliveryReason = insulinDeliveryReason
        self.isAutomatic = isAutomatic
        self.isManuallyEntered = isManuallyEntered
        self.isSuspend = isSuspend
        self.absorptionTime = absorptionTime
    }

    var sourceID: String { syncIdentifier ?? uuid.uuidString }
}

/// Metadata keys written by Loop (LoopKit) and Trio, read in addition to HealthKit's own.
public enum HealthMetadataKeys {
    public static let automaticallyIssued = "com.loopkit.InsulinKit.MetadataKeyAutomaticallyIssued"
    public static let manuallyEntered = "com.loopkit.InsulinKit.MetadataKeyManuallyEntered"
    public static let isSuspend = "com.loopkit.InsulinKit.MetadataKeyIsSuspend"
    public static let glucoseIsDisplayOnly = "com.loudnate.GlucoseKit.HKMetadataKey.GlucoseIsDisplayOnly"
    /// Seconds.
    public static let absorptionTime = "com.loopkit.AbsorptionTime"
    /// Minutes (older Loop versions).
    public static let legacyAbsorptionTimeMinutes = "com.loudnate.CarbKit.HKMetadataKey.AbsorptionTimeMinutes"
}

public enum HealthSampleMapper {
    public static func glucose(_ sample: HealthSample) -> GlucoseReading {
        let kind: GlucoseReading.Kind = sample.wasUserEntered ? .fingerstick : (sample.isDisplayOnly ? .calibration : .sensor)
        return GlucoseReading(date: sample.start, mgdL: sample.value, kind: kind, sourceID: sample.sourceID)
    }

    public static func insulin(_ sample: HealthSample) -> InsulinDose {
        switch sample.insulinDeliveryReason {
        case .basal:
            if sample.isSuspend {
                return InsulinDose(kind: .suspend, start: sample.start, end: sample.end, units: 0, sourceID: sample.sourceID)
            }
            let automatic = sample.isAutomatic ?? false
            return InsulinDose(kind: automatic ? .tempBasal : .basal, start: sample.start, end: sample.end,
                               units: sample.value, isAutomatic: automatic, sourceID: sample.sourceID)
        case .bolus, nil:
            return InsulinDose(kind: .bolus, start: sample.start, end: sample.end, units: sample.value,
                               isAutomatic: sample.isAutomatic ?? false, isExternal: sample.isManuallyEntered,
                               sourceID: sample.sourceID)
        }
    }

    public static func carbs(_ sample: HealthSample) -> CarbIntake {
        CarbIntake(date: sample.start, grams: sample.value, absorptionTime: sample.absorptionTime, sourceID: sample.sourceID)
    }
}
