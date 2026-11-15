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
}
