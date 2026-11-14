// Loop adapter for AIDReportKit.
//
// Add this file to the Loop app target (Loop/Loop/Managers/) and link the AIDReportKit and
// AIDReportUI products to that target. It reads Loop's own stores, so it works offline and sees
// exactly what the algorithm saw.
//
// Wiring (Settings → Support → "Statistics Report"):
// 1. SettingsViewModel takes `makeStatisticsReport: ((ReportDefinition) async throws -> TherapyReport)? = nil`
//    in its initializer and keeps it as a `let`.
// 2. StatusTableViewController passes it when it opens Settings, reading the managers when the
//    report is made, not when Settings opens:
//
//        makeStatisticsReport: { [weak self] definition in
//            guard let deviceManager = self?.deviceManager else { throw CancellationError() }
//            return try await deviceManager.makeStatisticsReport(definition)
//        },
//
// 3. SettingsView adds a `.statisticsReport` sheet and a Support row (once onboarding is
//    complete) presenting
//    `ReportExportView(ranges: DeviceDataManager.statisticsReportRanges, presetStore:, makeReport:)`.
//
// Verified against LoopKit/Loop `dev` (LoopWorkspace c50b6bb).

import AIDReportKit
import Foundation
import HealthKit
import LoopCore
import LoopKit

/// Feeds AIDReportKit from Loop's own stores, so a report sees what the algorithm saw and works offline.
///
/// The stores keep `Bundle.main.localCacheDuration` of history (7 days), so that is the longest
/// period a report can cover; see `statisticsReportRanges`.
final class LoopTherapyDataSource: TherapyDataSource {
    let info: DataSourceInfo
    private let glucoseStore: GlucoseStore
    private let doseStore: DoseStore
    private let carbStore: CarbStore

    init(
        glucoseStore: GlucoseStore,
        doseStore: DoseStore,
        carbStore: CarbStore,
        displayUnit: GlucoseUnit,
        appVersion: String? = Bundle.main.shortVersionString
    ) {
        self.glucoseStore = glucoseStore
        self.doseStore = doseStore
        self.carbStore = carbStore
        self.info = DataSourceInfo(app: .loop, appVersion: appVersion, displayUnit: displayUnit)
    }

    convenience init(deviceDataManager: DeviceDataManager) {
        self.init(
            glucoseStore: deviceDataManager.glucoseStore,
            doseStore: deviceDataManager.doseStore,
            carbStore: deviceDataManager.carbStore,
            displayUnit: deviceDataManager.displayGlucosePreference.unit == .millimolesPerLiter ? .mmolL : .mgdL
        )
    }

    func glucose(in interval: DateInterval) async throws -> [GlucoseReading] {
        try await glucoseStore.getGlucoseSamples(start: interval.start, end: interval.end).map { sample in
            let kind: GlucoseReading.Kind = sample.wasUserEntered ? .fingerstick : (sample.isDisplayOnly ? .calibration : .sensor)
            return GlucoseReading(
                date: sample.startDate,
                mgdL: sample.quantity.doubleValue(for: .milligramsPerDeciliter),
                kind: kind,
                sourceID: sample.syncIdentifier ?? sample.uuid?.uuidString
            )
        }
    }

    /// Normalized doses, as Loop's own charts and totals read them: pump events reconciled, in
    /// absolute units. Scheduled basal is only recorded between pump events, so time after the
    /// last one (and open-loop stretches) is filled from the basal schedule passed in
    /// `ReportOptions`; see `DeviceDataManager.makeStatisticsReport(_:)`.
    func insulin(in interval: DateInterval) async throws -> [InsulinDose] {
        let doses: [DoseEntry] = try await withCheckedThrowingContinuation { continuation in
            doseStore.getNormalizedDoseEntries(start: interval.start, end: interval.end) { result in
                switch result {
                case let .success(doses): continuation.resume(returning: doses)
                case let .failure(error): continuation.resume(throwing: error)
                }
            }
        }
        return doses.compactMap(Self.map)
    }

    func carbs(in interval: DateInterval) async throws -> [CarbIntake] {
        try await carbStore.getCarbEntries(start: interval.start, end: interval.end).map { entry in
            CarbIntake(
                date: entry.startDate,
                grams: entry.quantity.doubleValue(for: .gram()),
                absorptionTime: entry.absorptionTime,
                sourceID: entry.syncIdentifier ?? entry.uuid?.uuidString
            )
        }
    }

    static func map(_ dose: DoseEntry) -> InsulinDose? {
        // Absolute units as Loop totals them (`totalDelivery`) — never `netBasalUnits`, which is
        // relative to the schedule.
        let units = dose.unitsInDeliverableIncrements
        switch dose.type {
        case .bolus:
            return InsulinDose(kind: .bolus, start: dose.startDate, end: dose.endDate, units: units,
                               isAutomatic: dose.automatic ?? false, isExternal: dose.manuallyEntered,
                               sourceID: dose.syncIdentifier)
        case .basal:
            return InsulinDose(kind: .basal, start: dose.startDate, end: dose.endDate, units: units,
                               isAutomatic: false, sourceID: dose.syncIdentifier)
        case .tempBasal:
            return InsulinDose(kind: .tempBasal, start: dose.startDate, end: dose.endDate, units: units,
                               isAutomatic: dose.automatic ?? true, sourceID: dose.syncIdentifier)
        case .suspend:
            return InsulinDose(kind: .suspend, start: dose.startDate, end: dose.endDate, units: 0, sourceID: dose.syncIdentifier)
        case .resume:
            return nil
        }
    }
}

extension BasalSchedule {
    /// Loop's basal rate schedule, in the schedule's own time zone.
    init?(_ schedule: BasalRateSchedule) {
        self.init(
            entries: schedule.items.map { BasalSchedule.Entry(startOffset: $0.startTime, ratePerHour: $0.value) },
            timeZone: schedule.timeZone
        )
    }
}

extension ReportMetadata {
    /// Report header for Loop: devices and the settings that most change how the numbers read.
    static func loop(deviceDataManager: DeviceDataManager) -> ReportMetadata {
        let settings = deviceDataManager.loopManager.settings
        let closedLoop = settings.dosingEnabled
            ? NSLocalizedString("On", comment: "Statistics report: closed loop is on")
            : NSLocalizedString("Off", comment: "Statistics report: closed loop is off")
        return ReportMetadata(
            appName: Bundle.main.bundleDisplayName,
            appVersion: Bundle.main.shortVersionString,
            cgm: deviceDataManager.cgmManager?.localizedTitle,
            pump: deviceDataManager.pumpManager?.localizedTitle,
            settings: [
                .init(NSLocalizedString("Closed Loop", comment: "Statistics report: label of the closed loop setting"), closedLoop),
                .init(NSLocalizedString("Dosing Strategy", comment: "Statistics report: label of the dosing strategy setting"),
                      settings.automaticDosingStrategy.title)
            ]
        )
    }
}

extension DeviceDataManager {
    /// The ranges a statistics report can cover: no longer than the stores keep.
    static var statisticsReportRanges: [ReportRange] {
        ReportRange.presets(within: Bundle.main.localCacheDuration)
    }

    /// Builds a statistics report from Loop's stores, with devices and settings as they are now.
    @MainActor
    func makeStatisticsReport(_ definition: ReportDefinition) async throws -> TherapyReport {
        let source = LoopTherapyDataSource(deviceDataManager: self)
        let options = ReportOptions(
            basalSchedule: loopManager.settings.basalRateSchedule.flatMap { BasalSchedule($0) },
            metadata: .loop(deviceDataManager: self)
        )
        return try await AIDReport.generate(definition, from: source, options: options)
    }
}
