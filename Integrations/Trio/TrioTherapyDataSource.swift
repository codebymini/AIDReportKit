// Trio adapter for AIDReportKit.
//
// Add this file to the Trio app target (Trio/Sources/Modules/Stat/) and link the AIDReportKit
// and AIDReportUI products. It reads Trio's Core Data store through `CoreDataStack`, on named
// task contexts, the way the Stat module does.
//
// It goes together with `ReportExportSetup.swift` (the Stat state model's entry point) and two
// additions to the Stat provider, listed in that file.
//
// Verified against nightscout/Trio `dev` (3f6b238).

import AIDReportKit
import CoreData
import Foundation
import UIKit

/// AIDReportKit adapter: glucose, pump events and carbs from Trio's Core Data store.
///
/// Pump history holds what the pump was told (temp basals, boluses, suspends). Time no temp
/// basal covers runs at the profile rate, so pass the basal profile as
/// `ReportOptions.basalSchedule` (`BasalSchedule(trioProfile:)`) and the report fills it in. That
/// is today's profile for the whole period: Trio keeps no profile history.
/// Trio's own `GlucoseReading` (StatStateModel+Setup/GlucoseStatsSetup.swift) shadows the
/// package type in this module, hence `AIDReportKit.GlucoseReading` below.
final class TrioTherapyDataSource: TherapyDataSource {
    let info: DataSourceInfo

    init(displayUnit: GlucoseUnit, appVersion: String? = Bundle.main.releaseVersionNumber) {
        info = DataSourceInfo(app: .trio, appVersion: appVersion, displayUnit: displayUnit)
    }

    func glucose(in interval: DateInterval) async throws -> [AIDReportKit.GlucoseReading] {
        let rows = try await rows(
            of: GlucoseStored.self,
            named: "glucose",
            predicate: NSPredicate(format: "date >= %@ AND date < %@", interval.start as NSDate, interval.end as NSDate),
            key: "date",
            properties: ["date", "glucose", "isManual", "id"]
        )
        return rows.compactMap { row in
            guard let date = row["date"] as? Date, let glucose = row["glucose"] as? NSNumber else { return nil }
            return AIDReportKit.GlucoseReading(
                date: date,
                mgdL: glucose.doubleValue,
                kind: row["isManual"] as? Bool == true ? .fingerstick : .sensor,
                sourceID: (row["id"] as? UUID)?.uuidString
            )
        }
    }

    func insulin(in interval: DateInterval) async throws -> [InsulinDose] {
        // Start early so a temp basal running into the interval is included; the pipeline clamps it.
        let from = interval.start.addingTimeInterval(-6 * 3600)
        // Scheduled-basal rows are open-ended markers, not delivery spans; Trio's own queries skip them too.
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "TrioTherapyDataSource.insulin"
        let result = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: PumpEventStored.self,
            onContext: context,
            predicate: NSPredicate(
                format: "timestamp >= %@ AND timestamp < %@ AND \(NSPredicate.notScheduledBasal)",
                from as NSDate,
                interval.end as NSDate
            ),
            key: "timestamp",
            ascending: true,
            relationshipKeyPathsForPrefetching: ["bolus", "tempBasal"]
        )
        let doses = try await context.perform {
            guard let events = result as? [PumpEventStored] else {
                throw CoreDataError.fetchError(function: #function, file: #file)
            }
            return Self.map(events, from: from, until: interval.end)
        }
        // Trio records a new temp basal every loop cycle without closing the previous one.
        return BasalTimeline.truncatingOverlaps(doses)
    }

    func carbs(in interval: DateInterval) async throws -> [CarbIntake] {
        let rows = try await rows(
            of: CarbEntryStored.self,
            named: "carbs",
            predicate: NSPredicate(format: "date >= %@ AND date < %@", interval.start as NSDate, interval.end as NSDate),
            key: "date",
            properties: ["date", "carbs", "fat", "protein", "isFPU", "id"]
        )
        return rows.compactMap { row in
            guard let date = row["date"] as? Date, let grams = row["carbs"] as? Double else { return nil }
            let isFPU = row["isFPU"] as? Bool == true
            let fat = row["fat"] as? Double ?? 0
            let protein = row["protein"] as? Double ?? 0
            return CarbIntake(
                date: date,
                grams: grams,
                fatGrams: isFPU || fat == 0 ? nil : fat,
                proteinGrams: isFPU || protein == 0 ? nil : protein,
                isFatProteinEquivalent: isFPU,
                sourceID: (row["id"] as? UUID)?.uuidString
            )
        }
    }

    /// Attribute values only, as dictionaries, read on a named task context the way the Stat
    /// module reads Core Data: a 3-month report is tens of thousands of rows.
    private func rows<Entity: NSManagedObject>(
        of type: Entity.Type,
        named name: String,
        predicate: NSPredicate,
        key: String,
        properties: [String]
    ) async throws -> [[String: Any]] {
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "TrioTherapyDataSource.\(name)"
        let result = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: type,
            onContext: context,
            predicate: predicate,
            key: key,
            ascending: true,
            propertiesToFetch: properties
        )
        guard let rows = result as? [[String: Any]] else {
            throw CoreDataError.fetchError(function: #function, file: #file)
        }
        return rows
    }

    /// Must be called on the context's queue.
    private static func map(_ events: [PumpEventStored], from windowStart: Date, until end: Date) -> [InsulinDose] {
        let suspends = suspensions(in: events, from: windowStart, until: end)
        var doses = suspends

        for event in events {
            guard let timestamp = event.timestamp else { continue }

            if let bolus = event.bolus, let amount = bolus.amount?.doubleValue {
                doses.append(.bolus(
                    at: timestamp,
                    units: amount,
                    isAutomatic: bolus.isSMB,
                    isExternal: bolus.isExternal,
                    sourceID: event.id
                ))
            } else if let temp = event.tempBasal, let rate = temp.rate?.doubleValue {
                let start = temp.startDate ?? timestamp
                let stop = temp.endDate ?? start.addingTimeInterval(TimeInterval(temp.duration) * 60)
                guard stop > start else { continue }
                var dose = InsulinDose.basal(
                    .tempBasal,
                    start: start,
                    end: stop,
                    ratePerHour: rate,
                    isAutomatic: true,
                    sourceID: event.id
                )
                // A finalized row carries what the pump actually delivered, suspensions included.
                // The report takes suspended time off every basal dose, so spread that total over
                // the unsuspended time first (as the TDD chart does) or it is taken off twice.
                // An open row has no real end yet; the superseding logic prorates its rate.
                if temp.endDate != nil, let delivered = temp.deliveredUnits?.doubleValue {
                    let span = DateInterval(start: start, end: stop)
                    let suspended = suspends.reduce(0) {
                        $0 + (span.intersection(with: DateInterval(start: $1.start, end: $1.end))?.duration ?? 0)
                    }
                    let running = span.duration - suspended
                    dose.units = running > 0 ? delivered * span.duration / running : delivered
                }
                doses.append(dose)
            }
        }
        return doses
    }

    /// Suspend/resume pairs as suspensions. A suspend with no resume is still running; a resume
    /// with nothing before it means the window opened with the pump already suspended.
    private static func suspensions(in events: [PumpEventStored], from windowStart: Date, until end: Date) -> [InsulinDose] {
        var suspensions: [InsulinDose] = []
        var suspendedAt: (date: Date, id: String?)?
        var nothingBefore = true

        for event in events {
            guard let timestamp = event.timestamp else { continue }

            if event.type == PumpEventStored.EventType.pumpSuspend.rawValue {
                if suspendedAt == nil { suspendedAt = (timestamp, event.id) }
            } else if event.type == PumpEventStored.EventType.pumpResume.rawValue {
                if let suspend = suspendedAt ?? (nothingBefore ? (windowStart, event.id) : nil), timestamp > suspend.date {
                    suspensions
                        .append(InsulinDose(kind: .suspend, start: suspend.date, end: timestamp, units: 0, sourceID: suspend.id))
                }
                suspendedAt = nil
            } else if event.tempBasal == nil {
                continue // a bolus says nothing about whether basal was running
            }
            nothingBefore = false
        }
        if let suspend = suspendedAt, end > suspend.date {
            suspensions.append(InsulinDose(kind: .suspend, start: suspend.date, end: end, units: 0, sourceID: suspend.id))
        }
        return suspensions
    }
}

extension BasalSchedule {
    /// From `Stat.Provider.basalProfile()`.
    init?(trioProfile: [BasalProfileEntry], timeZone: TimeZone = .current) {
        self.init(
            entries: trioProfile.map {
                BasalSchedule.Entry(
                    startOffset: TimeInterval($0.minutes * 60),
                    ratePerHour: NSDecimalNumber(decimal: $0.rate).doubleValue
                )
            },
            timeZone: timeZone
        )
    }
}

/// Trio's stored therapy settings, read together for a report (see `Stat.Provider`).
struct TrioTherapySettingsFiles {
    var sensitivities: InsulinSensitivities?
    var carbRatios: CarbRatios?
    var targets: BGTargets?
    var pump: PumpSettings?
}

extension TherapySettingsSnapshot {
    /// Trio's settings: ISF, carb ratios and targets converted to mg/dL and grams; limits, the
    /// insulin model, SMB and the algorithm under Trio's own names.
    init(trio files: TrioTherapySettingsFiles, settings: TrioSettings, preferences: Preferences) {
        let f = ReportFormatter(unit: settings.units == .mmolL ? .mmolL : .mgdL, timeZone: .current)
        func number(_ value: Decimal) -> Double { NSDecimalNumber(decimal: value).doubleValue }
        func mgdL(_ value: Decimal, _ units: GlucoseUnits) -> Double {
            units == .mmolL ? number(value) * GlucoseUnit.mgdLPerMmolL : number(value)
        }
        func onOff(_ value: Bool) -> String { value ? String(localized: "On") : String(localized: "Off") }
        func minutes(_ value: Decimal) -> String { "\(f.compact(number(value))) min" }

        let sensitivities = files.sensitivities.map { isf in
            isf.sensitivities.map { Entry(startOffset: TimeInterval($0.offset * 60), value: mgdL($0.sensitivity, isf.units)) }
        } ?? []
        // Ratios in exchanges have no fixed gram value; leave them out rather than guess.
        let carbRatios = files.carbRatios.flatMap { ratios in
            ratios.units == .grams ? ratios.schedule
                .map { Entry(startOffset: TimeInterval($0.offset * 60), value: number($0.ratio)) } : nil
        } ?? []
        let targets = files.targets.map { targets in
            targets.targets.map {
                TargetRange(
                    startOffset: TimeInterval($0.offset * 60),
                    low: mgdL($0.low, targets.units),
                    high: mgdL($0.high, targets.units)
                )
            }
        } ?? []

        var limits: [ReportMetadata.Item] = [
            .init(String(localized: "Max IOB"), "\(f.compact(number(preferences.maxIOB))) U"),
            .init(String(localized: "Max COB"), "\(f.compact(number(preferences.maxCOB))) g")
        ]
        var insulinModel: [ReportMetadata.Item] = [
            .init(String(localized: "Insulin Curve"), {
                switch preferences.curve {
                case .rapidActing: return String(localized: "Rapid-Acting")
                case .ultraRapid: return String(localized: "Ultra-Rapid")
                case .bilinear: return String(localized: "Bilinear")
                }
            }())
        ]
        if preferences.useCustomPeakTime {
            insulinModel.append(.init(String(localized: "Insulin Peak Time"), minutes(preferences.insulinPeakTime)))
        }
        if let pump = files.pump {
            limits += [
                .init(String(localized: "Max Basal"), "\(f.rate(number(pump.maxBasal))) U/h"),
                .init(String(localized: "Max Bolus"), "\(f.compact(number(pump.maxBolus))) U")
            ]
            insulinModel
                .append(.init(String(localized: "Duration of Insulin Action"), "\(f.compact(number(pump.insulinActionCurve))) h"))
        }

        self.init(
            carbRatios: carbRatios,
            insulinSensitivities: sensitivities,
            targets: targets,
            groups: [
                .init(String(localized: "Limits"), limits),
                .init(String(localized: "Insulin Model"), insulinModel),
                .init(String(localized: "SMB"), [
                    .init(String(localized: "Enable SMB Always"), onOff(preferences.enableSMBAlways)),
                    .init(String(localized: "Enable SMB With COB"), onOff(preferences.enableSMBWithCOB)),
                    .init(String(localized: "Enable SMB With Temptarget"), onOff(preferences.enableSMBWithTemptarget)),
                    .init(String(localized: "Enable SMB After Carbs"), onOff(preferences.enableSMBAfterCarbs)),
                    .init(String(localized: "Enable SMB With High BG"), onOff(preferences.enableSMB_high_bg)),
                    .init(String(localized: "Max SMB Basal Minutes"), minutes(preferences.maxSMBBasalMinutes)),
                    .init(String(localized: "Max UAM SMB Basal Minutes"), minutes(preferences.maxUAMSMBBasalMinutes)),
                    .init(String(localized: "SMB Interval"), minutes(preferences.smbInterval))
                ]),
                .init(String(localized: "Algorithm"), [
                    .init(String(localized: "Dosing Mode"), settings.dosingMode.displayName),
                    .init(String(localized: "Enable UAM"), onOff(preferences.enableUAM)),
                    .init(String(localized: "Dynamic ISF"), onOff(preferences.useNewFormula)),
                    .init(
                        String(localized: "Adjustment Factor"),
                        f.compact(number(
                            preferences.useNewFormula && preferences.sigmoid
                                ? preferences.adjustmentFactorSigmoid : preferences.adjustmentFactor
                        ))
                    ),
                    .init(
                        String(localized: "Autosens"),
                        "\(f.compact(number(preferences.autosensMin)))–\(f.compact(number(preferences.autosensMax)))"
                    )
                ])
            ]
        )
    }
}

extension ReportMetadata {
    /// Report header: hardware, software and the settings that most change how the numbers read
    /// (the same ones as the Statistics PDF export, nightscout/Trio#1746).
    @MainActor static func trio(settings: TrioSettings, preferences: Preferences, pumpName: String) -> ReportMetadata {
        func onOff(_ value: Bool) -> String { value ? String(localized: "On") : String(localized: "Off") }
        // A plugin CGM (Dexcom, Libre, …) is named by the device catalog, as on the Home screen.
        let pluginCGM = settings.cgm == .plugin
            ? DeviceCatalog.cgmModels.first { $0.id == settings.cgmPluginIdentifier }?.displayName
            : nil
        let smb = preferences.enableSMBAlways || preferences.enableSMBWithCOB || preferences.enableSMBWithTemptarget
            || preferences.enableSMBAfterCarbs || preferences.enableSMB_high_bg
        return ReportMetadata(
            appName: "Trio",
            appVersion: Bundle.main.releaseVersionNumber,
            buildDate: BuildDetails.shared.buildDateString,
            cgm: pluginCGM ?? settings.cgm.displayName,
            pump: pumpName,
            device: UIDevice.current.model,
            settings: [
                .init(String(localized: "Dosing Mode"), settings.dosingMode.displayName),
                .init(String(localized: "SMB"), onOff(smb)),
                .init(String(localized: "UAM"), onOff(preferences.enableUAM)),
                .init(String(localized: "Dynamic ISF"), onOff(preferences.useNewFormula))
            ]
        )
    }
}
