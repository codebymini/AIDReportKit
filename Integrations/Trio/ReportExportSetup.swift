// Trio entry point for AIDReportKit: add to Trio/Sources/Modules/Stat/StatStateModel+Setup/.
//
// Data access goes through the module's provider, so `StatProvider` (StatDataFlow.swift) gains
//
//     func basalProfile() async -> [BasalProfileEntry]
//     var pumpName: String { get }
//     func therapySettings() async -> TrioTherapySettingsFiles
//
// and `Stat.Provider` (StatProvider.swift) implements them:
//
//     func basalProfile() async -> [BasalProfileEntry] {
//         await storage.retrieveAsync(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self) ?? []
//     }
//
//     var pumpName: String { deviceManager.pumpName.value }
//
//     func therapySettings() async -> TrioTherapySettingsFiles {
//         TrioTherapySettingsFiles(
//             sensitivities: await storage.retrieveAsync(OpenAPS.Settings.insulinSensitivities, as: InsulinSensitivities.self),
//             carbRatios: await storage.retrieveAsync(OpenAPS.Settings.carbRatios, as: CarbRatios.self),
//             targets: await storage.retrieveAsync(OpenAPS.Settings.bgTargets, as: BGTargets.self),
//             pump: await storage.retrieveAsync(OpenAPS.Settings.settings, as: PumpSettings.self)
//         )
//     }
//
// The Statistics screen (StatRootView) presents the sheet from its share button:
//
//     ReportExportView(
//         presetStore: JSONFileReportPresetStore.applicationSupport(),
//         background: appState.trioBackgroundColor(for: colorScheme)
//     ) { definition in
//         try await state.makeAIDReport(definition)
//     }

import AIDReportKit
import Foundation

extension Stat.StateModel {
    /// Builds the statistics report the export sheet turns into a PDF: Trio's store, the current
    /// basal profile and the settings in force now.
    @MainActor func makeAIDReport(_ definition: ReportDefinition) async throws -> TherapyReport {
        let settings = settingsManager.settings
        let options = ReportOptions(
            basalSchedule: BasalSchedule(trioProfile: await provider.basalProfile()),
            therapySettings: TherapySettingsSnapshot(
                trio: await provider.therapySettings(),
                settings: settings,
                preferences: settingsManager.preferences
            ),
            metadata: .trio(settings: settings, preferences: settingsManager.preferences, pumpName: provider.pumpName)
        )
        let source = TrioTherapyDataSource(displayUnit: settings.units == .mmolL ? .mmolL : .mgdL)
        do {
            return try await AIDReport.generate(definition, from: source, options: options)
        } catch {
            warning(.ui, "Building the statistics report failed", error: error)
            throw error
        }
    }
}
