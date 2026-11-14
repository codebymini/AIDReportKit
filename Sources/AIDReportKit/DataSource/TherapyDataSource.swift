import Foundation

/// The seam between AIDReportKit and wherever data lives.
///
/// Implementations shipped with the package: `NightscoutTherapyDataSource` (AIDReportNightscout),
/// `HealthKitTherapyDataSource` (AIDReportHealthKit) and `MergedTherapyDataSource` (combine several).
/// Host apps add their own for their local stores; see `Integrations/` for Loop, Trio and LoopFollow.
///
/// Contract (checked by `AdapterConformance` in AIDReportTesting):
/// - Glucose in mg/dL.
/// - Insulin `units` are absolute delivered units, not net-of-scheduled-basal.
/// - Results should cover the interval; they may extend past its edges (the pipeline clamps).
public protocol TherapyDataSource {
    var info: DataSourceInfo { get }

    func glucose(in interval: DateInterval) async throws -> [GlucoseReading]
    func insulin(in interval: DateInterval) async throws -> [InsulinDose]
    func carbs(in interval: DateInterval) async throws -> [CarbIntake]

    /// Fetches all three. Override when the backing store can do it in fewer round trips.
    func dataset(in interval: DateInterval) async throws -> TherapyDataset
}

extension TherapyDataSource {
    public func dataset(in interval: DateInterval) async throws -> TherapyDataset {
        let glucose = try await glucose(in: interval)
        let insulin = try await insulin(in: interval)
        let carbs = try await carbs(in: interval)
        return TherapyDataset(interval: interval, source: info, glucose: glucose, insulin: insulin, carbs: carbs)
    }
}
