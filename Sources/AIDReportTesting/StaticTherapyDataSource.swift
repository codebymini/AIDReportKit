import AIDReportKit
import Foundation

/// An in-memory source backed by a fixed dataset. Useful for previews, tests and snapshotting
/// what a host app has already loaded.
public struct StaticTherapyDataSource: TherapyDataSource {
    public let dataset: TherapyDataset
    public var info: DataSourceInfo { dataset.source }

    public init(_ dataset: TherapyDataset) {
        self.dataset = dataset
    }

    public func glucose(in interval: DateInterval) async throws -> [GlucoseReading] {
        dataset.glucose.filter { interval.containsHalfOpen($0.date) }
    }

    public func insulin(in interval: DateInterval) async throws -> [InsulinDose] {
        dataset.insulin.filter { dose in
            dose.kind == .bolus ? interval.containsHalfOpen(dose.start) : (dose.end > interval.start && dose.start < interval.end)
        }
    }

    public func carbs(in interval: DateInterval) async throws -> [CarbIntake] {
        dataset.carbs.filter { interval.containsHalfOpen($0.date) }
    }
}
