#if canImport(HealthKit)
import AIDReportKit
import Foundation
import HealthKit

/// Reads blood glucose, insulin delivery and dietary carbohydrates from Apple Health.
///
/// Loop and Trio both write to Health, as do CGM and pen apps, so the same reading can appear
/// several times. Use `includedSourceBundleIDs` to pick sources, or combine with Nightscout via
/// `MergedTherapyDataSource`, which de-duplicates by time.
@available(iOS 15.0, macOS 13.0, watchOS 8.0, *)
public final class HealthKitTherapyDataSource: TherapyDataSource {
    public let info: DataSourceInfo
    /// Only samples written by these apps; `nil` reads every source.
    public var includedSourceBundleIDs: Set<String>?
    private let store: HKHealthStore

    public init(
        healthStore: HKHealthStore = HKHealthStore(),
        info: DataSourceInfo = DataSourceInfo(app: .appleHealth),
        includedSourceBundleIDs: Set<String>? = nil
    ) {
        self.store = healthStore
        self.info = info
        self.includedSourceBundleIDs = includedSourceBundleIDs
    }

    public static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    public static let readTypes: Set<HKObjectType> = [
        HKQuantityType(.bloodGlucose),
        HKQuantityType(.insulinDelivery),
        HKQuantityType(.dietaryCarbohydrates),
    ]

    /// Asks for read access. HealthKit never reveals whether read access was granted;
    /// a denied type simply returns no samples.
    public func requestAuthorization() async throws {
        try await store.requestAuthorization(toShare: [], read: Self.readTypes)
    }

    public func glucose(in interval: DateInterval) async throws -> [GlucoseReading] {
        let mgdL = HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci))
        return try await samples(.bloodGlucose, unit: mgdL, in: interval).map(HealthSampleMapper.glucose)
    }

    public func insulin(in interval: DateInterval) async throws -> [InsulinDose] {
        try await samples(.insulinDelivery, unit: .internationalUnit(), in: interval).map(HealthSampleMapper.insulin)
    }

    public func carbs(in interval: DateInterval) async throws -> [CarbIntake] {
        try await samples(.dietaryCarbohydrates, unit: .gram(), in: interval).map(HealthSampleMapper.carbs)
    }

    // MARK: - Query

    private func samples(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit, in interval: DateInterval) async throws -> [HealthSample] {
        let type = HKQuantityType(identifier)
        // No options: include samples overlapping the interval, so basal segments crossing the edges are kept.
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end, options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        let results: [HKQuantitySample] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (samples as? [HKQuantitySample]) ?? [])
                }
            }
            store.execute(query)
        }

        return results
            .filter { includedSourceBundleIDs?.contains($0.sourceRevision.source.bundleIdentifier) ?? true }
            .map { Self.healthSample($0, unit: unit) }
    }

    static func healthSample(_ sample: HKQuantitySample, unit: HKUnit) -> HealthSample {
        let metadata = sample.metadata ?? [:]
        func bool(_ key: String) -> Bool? { (metadata[key] as? NSNumber)?.boolValue }

        let absorption: TimeInterval? = (metadata[HealthMetadataKeys.absorptionTime] as? NSNumber)?.doubleValue
            ?? (metadata[HealthMetadataKeys.legacyAbsorptionTimeMinutes] as? NSNumber).map { $0.doubleValue * 60 }

        return HealthSample(
            start: sample.startDate,
            end: sample.endDate,
            value: sample.quantity.doubleValue(for: unit),
            uuid: sample.uuid,
            sourceBundleID: sample.sourceRevision.source.bundleIdentifier,
            syncIdentifier: metadata[HKMetadataKeySyncIdentifier] as? String,
            wasUserEntered: bool(HKMetadataKeyWasUserEntered) ?? false,
            isDisplayOnly: bool(HealthMetadataKeys.glucoseIsDisplayOnly) ?? false,
            insulinDeliveryReason: (metadata[HKMetadataKeyInsulinDeliveryReason] as? NSNumber)
                .flatMap { HealthSample.InsulinDeliveryReason(rawValue: $0.intValue) },
            isAutomatic: bool(HealthMetadataKeys.automaticallyIssued),
            isManuallyEntered: bool(HealthMetadataKeys.manuallyEntered) ?? false,
            isSuspend: bool(HealthMetadataKeys.isSuspend) ?? false,
            absorptionTime: absorption
        )
    }
}
#endif
