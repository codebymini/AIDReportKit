import AIDReportKit
import AIDReportTesting
import XCTest

final class ReportTests: XCTestCase {
    private let generator = SyntheticTherapyGenerator(days: 14)

    private func makeReport(_ definition: ReportDefinition = ReportDefinition(name: "Clinic visit", range: .twoWeeks, sections: ReportSection.allCases)) async throws -> TherapyReport {
        try await AIDReport.generate(
            definition,
            from: StaticTherapyDataSource(generator.makeDataset()),
            options: ReportOptions(metadata: ReportMetadata(appName: "Trio", cgm: "Dexcom G7", settings: [.init("SMB", "On")])),
            now: generator.interval.end
        )
    }

    func testPipelineProducesSummaryDailyAndAGP() async throws {
        let report = try await makeReport()
        let glucose = try XCTUnwrap(report.summary.glucose)
        XCTAssertGreaterThan(glucose.readingCount, 3500)
        XCTAssertGreaterThan(glucose.coverage, 0.95)
        XCTAssertEqual(report.daily.count, 14)
        XCTAssertEqual(report.agp.buckets.count, 24)
        XCTAssertEqual(report.summary.carbs.entryCount, 42)
        XCTAssertGreaterThan(report.summary.insulin.averageDailyDose, 10)
        XCTAssertFalse(report.validation.hasErrors)
        XCTAssertEqual(report.title, "Glucose Report") // the preset is named "Clinic visit"; that name is not printed
    }

    func testByDaySectionsAreDroppedForSingleDayReports() {
        let definition = ReportDefinition(range: .day, sections: [.overview, .glucoseDistributionByDay, .glucosePercentileByDay, .dataQuality])
        let interval = ReportRange.day.resolve(now: t0 + day)
        XCTAssertEqual(definition.unsupportedSections(for: interval), [.glucoseDistributionByDay, .glucosePercentileByDay])
    }

    func testBasalScheduleSuppressesCoverageWarning() throws {
        let raw = dataset(glucose: readings(Array(repeating: 110, count: 288)), insulin: [.bolus(at: t0 + hour, units: 3)])
        let withoutSchedule = ReportBuilder().build(.standard, from: raw, now: t0 + day)
        XCTAssertFalse(withoutSchedule.validation.issues(withCode: .insulinLowBasalCoverage).isEmpty)

        let schedule = try XCTUnwrap(BasalSchedule(entries: [.init(startOffset: 0, ratePerHour: 1)], timeZone: utc))
        let withSchedule = ReportBuilder(options: ReportOptions(basalSchedule: schedule)).build(.standard, from: raw, now: t0 + day)
        XCTAssertTrue(withSchedule.validation.issues(withCode: .insulinLowBasalCoverage).isEmpty)
        // Filled from the first to the last record (00:00–23:55), not past the data.
        XCTAssertEqual(withSchedule.summary.insulin.basalUnits, 287.0 * 5 / 60, accuracy: 1e-6)
    }

    func testMarkdownHasSectionsInDefinitionOrder() async throws {
        let sections: [ReportSection] = [.carbsTotals, .overview, .glycemiaRiskIndex]
        let report = try await makeReport(ReportDefinition(name: "", range: .twoWeeks, sections: sections))
        let markdown = MarkdownReportRenderer().render(report)
        let positions = sections.map { try? XCTUnwrap(markdown.range(of: "## \($0.title)")).lowerBound }
        XCTAssertEqual(positions.compactMap { $0 }.count, 3)
        XCTAssertEqual(positions.compactMap { $0 }, positions.compactMap { $0 }.sorted())
        XCTAssertTrue(markdown.hasPrefix("# Glucose Report\n"))
        XCTAssertTrue(markdown.contains("**CGM:** Dexcom G7"))
    }

    func testJSONRoundTrip() async throws {
        let report = try await makeReport()
        let renderer = JSONReportRenderer()
        let decoded = try renderer.decode(renderer.render(report))
        XCTAssertEqual(decoded.summary.carbs, report.summary.carbs)
        XCTAssertEqual(decoded.daily.count, report.daily.count)
        XCTAssertEqual(decoded.definition, report.definition)
        XCTAssertEqual(decoded.schemaVersion, TherapyReport.currentSchemaVersion)
    }

    func testDailyCSV() async throws {
        let report = try await makeReport()
        let lines = CSVExporter().daily(report).split(separator: "\n")
        XCTAssertEqual(lines.count, 15)
        XCTAssertTrue(lines[0].hasPrefix("date,readings,mean_mgdl"))
        XCTAssertTrue(lines[1].hasPrefix("2026-01-01,"))
    }

    func testDisplayUnitOnlyAffectsRendering() async throws {
        var data = generator.makeDataset()
        data.source.displayUnit = .mmolL
        let report = ReportBuilder().build(.standard, from: data, now: generator.interval.end)
        XCTAssertGreaterThan(try XCTUnwrap(report.summary.glucose).mean, 50) // still mg/dL internally
        XCTAssertTrue(MarkdownReportRenderer().render(report).contains("mmol/L"))
    }

    func testSyntheticGeneratorIsDeterministic() {
        XCTAssertEqual(SyntheticTherapyGenerator(seed: 7, days: 3).makeDataset(), SyntheticTherapyGenerator(seed: 7, days: 3).makeDataset())
        XCTAssertNotEqual(SyntheticTherapyGenerator(seed: 7, days: 3).makeDataset(), SyntheticTherapyGenerator(seed: 8, days: 3).makeDataset())
    }
}

final class PresetStoreTests: XCTestCase {
    func testUpsertDeleteAndOrdering() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("presets.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = JSONFileReportPresetStore(url: url)
        XCTAssertEqual(try store.presets(), [])

        var older = ReportPreset(name: "Monthly", definition: ReportDefinition(range: .month), createdAt: t0)
        let newer = ReportPreset(name: "Endo visit", definition: ReportDefinition(range: .threeMonths, sections: [.overview, .glycemiaRiskIndex]), createdAt: t0 + day)
        try store.upsert(older)
        try store.upsert(newer)
        XCTAssertEqual(try store.presets().map(\.name), ["Endo visit", "Monthly"])

        older.name = "Monthly review"
        try store.upsert(older)
        XCTAssertEqual(try store.presets().map(\.name), ["Endo visit", "Monthly review"])

        try store.delete(id: newer.id)
        XCTAssertEqual(try store.presets().map(\.name), ["Monthly review"])
        XCTAssertEqual(try store.presets().first?.definition.range, .month)
    }
}

final class ConformanceTests: XCTestCase {
    func testSyntheticSourceConforms() async throws {
        let generator = SyntheticTherapyGenerator(days: 3)
        let failures = try await AdapterConformance.check(
            StaticTherapyDataSource(generator.makeDataset()),
            interval: generator.interval,
            now: generator.interval.end
        )
        XCTAssertEqual(failures, [])
    }

    func testBrokenAdapterIsCaught() {
        let broken = dataset(
            glucose: readings([5.4, 6.0, 7.1]) + readings([6.2], start: t0 + hour).map { GlucoseReading(date: $0.date, mgdL: $0.mgdL, sourceID: "g0") },
            insulin: [
                .basal(start: t0, end: t0 + minutes(30), ratePerHour: 1),
                .basal(start: t0 + minutes(5), end: t0 + minutes(35), ratePerHour: 1),
            ]
        )
        let checks = Set(AdapterConformance.check(broken, now: t0 + day).map(\.check))
        XCTAssertTrue(checks.contains("ids.unique"))
        XCTAssertTrue(checks.contains("insulin.basalOverlap"))
        XCTAssertTrue(checks.contains("validation.glucose.likelyMmolL"))
    }

    func testRangePresetsWithinAHostsHistory() {
        // Loop's stores keep 7 days: a month would average 7 days of insulin over 30.
        XCTAssertEqual(ReportRange.presets(within: 7 * day), [.day, .week])
        XCTAssertEqual(ReportRange.presets(within: 90 * day), ReportRange.presets)
        XCTAssertEqual(ReportRange.presets(within: hour), [])
    }

    func testPresetsNamingARemovedSectionStillLoad() throws {
        // Saved before the AGP page (glucosePercentileByTime) was removed.
        let json = #"{"name": "Endo visit", "range": {"lastDays": {"_0": 90}}, "sections": ["overview", "glucosePercentileByTime", "glucoseDistribution"]}"#
        let definition = try JSONDecoder().decode(ReportDefinition.self, from: Data(json.utf8))
        XCTAssertEqual(definition.name, "Endo visit")
        XCTAssertEqual(definition.range, .threeMonths)
        XCTAssertEqual(definition.sections, [.overview, .glucoseDistribution])
        // And what it writes reads back the same.
        XCTAssertEqual(try JSONDecoder().decode(ReportDefinition.self, from: JSONEncoder().encode(definition)), definition)
    }

    func testSettingsAreCarriedWithTheBasalSchedule() async throws {
        let basal = try XCTUnwrap(BasalSchedule(entries: [.init(startOffset: 0, ratePerHour: 0.8), .init(startOffset: 12 * hour, ratePerHour: 1.025)], timeZone: utc))
        let settings = TherapySettingsSnapshot(
            carbRatios: [.init(startOffset: 0, value: 10), .init(startOffset: 11 * hour, value: 7.5)],
            insulinSensitivities: [.init(startOffset: 0, value: 45)],
            targets: [.init(startOffset: 0, low: 100, high: 110)],
            groups: [.init("Limits", [.init("Max IOB", "6 U")]), .init("Empty", [])]
        )
        let definition = ReportDefinition(range: .lastDays(2), sections: [.insulinTotalDailyDose, .therapySettings])
        let dataset = SyntheticTherapyGenerator(days: 2).makeDataset()
        let report = ReportBuilder(options: ReportOptions(basalSchedule: basal, therapySettings: settings)).build(definition, from: dataset, now: dataset.interval.end)

        XCTAssertEqual(report.settings?.basalSchedule, basal, "the report's basal schedule is printed with the other settings")
        XCTAssertEqual(report.settings?.groups.map(\.title), ["Limits"], "empty groups are dropped")
        let schedules = report.insulinSchedules(ReportFormatter(report: report))
        XCTAssertEqual(schedules.map(\.kind), [.basalRate, .carbRatio, .insulinSensitivity])
        XCTAssertEqual(schedules[0].range, "0.80–1.025", "printed next to the bar")
        XCTAssertEqual(schedules[0].rows.map(\.startOffset), [0, 12 * hour])
        XCTAssertNil(schedules[2].range, "one value has no range")
        let markdown = MarkdownReportRenderer().render(report)
        for expected in ["## Insulin", "**Basal rates (U/h)** · 21.9 U per day", "| 12:00 | 1.025 |", "| 00:00 | 0.80 |",
                         "**Carb ratios (g/U)**", "| 11:00 | 7.5 |", "| 00:00 | 10 |", "**Insulin sensitivity (mg/dL per U)**", "| 00:00 | 45 |",
                         "## Settings", "**Glucose targets (mg/dL)**", "| 00:00 | 100–110 |", "**Limits**", "| Max IOB | 6 U |",
                         TherapyReport.settingsNote] {
            XCTAssertTrue(markdown.contains(expected), "Markdown is missing: \(expected)")
        }

        // Basal schedule alone still makes the Insulin page's table; Settings says there is nothing else.
        let basalOnly = ReportBuilder(options: ReportOptions(basalSchedule: basal)).build(definition, from: dataset, now: dataset.interval.end)
        XCTAssertEqual(basalOnly.insulinSchedules(ReportFormatter(report: basalOnly)).count, 1)
        XCTAssertTrue(MarkdownReportRenderer().render(basalOnly).contains("The app supplied no other settings."))
        XCTAssertNil(ReportBuilder().build(definition, from: dataset, now: dataset.interval.end).settings)
    }

    func testSettingsInMmol() throws {
        let settings = TherapySettingsSnapshot(insulinSensitivities: [.init(startOffset: 0, value: 45)], targets: [.init(startOffset: 0, low: 99, high: 99)])
        let synthetic = SyntheticTherapyGenerator(days: 1).makeDataset()
        let dataset = TherapyDataset(interval: synthetic.interval, source: DataSourceInfo(app: .synthetic, displayUnit: .mmolL, timeZone: utc),
                                     glucose: synthetic.glucose, insulin: synthetic.insulin, carbs: synthetic.carbs)
        let report = ReportBuilder(options: ReportOptions(therapySettings: settings)).build(ReportDefinition(range: .day, sections: [.therapySettings]), from: dataset, now: dataset.interval.end)
        let f = ReportFormatter(report: report)
        XCTAssertEqual(report.insulinSchedules(f).first?.title, "Insulin sensitivity (mmol/L per U)")
        XCTAssertEqual(report.insulinSchedules(f).first?.rows.first?.value, "2.5")
        XCTAssertEqual(report.targetSchedule(f)?.rows.first?.value, "5.5", "a single target prints once")
    }
}
