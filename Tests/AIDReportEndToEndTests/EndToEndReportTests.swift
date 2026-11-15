import AIDReportHealthKit
import AIDReportKit
import AIDReportNightscout
import AIDReportTesting
import AIDReportUI
import XCTest
#if canImport(PDFKit)
import PDFKit
#endif

/// Runs the hand-computed `GoldenScenario` through the whole pipeline — every data source, the
/// sanitizer, the aggregator and every renderer — and checks the numbers a reader would see.
final class EndToEndReportTests: XCTestCase {
    private typealias S = GoldenScenario
    private let accuracy = 1e-6

    private var options: ReportOptions {
        ReportOptions(basalSchedule: S.schedule, metadata: ReportMetadata(appName: "Trio", cgm: "Dexcom G7"))
    }

    private var definition: ReportDefinition {
        ReportDefinition(name: "Golden", range: .custom(S.interval), sections: ReportSection.allCases)
    }

    private func goldenReport() async throws -> TherapyReport {
        try await AIDReport.generate(definition, from: StaticTherapyDataSource(S.dataset()), options: options, now: S.end)
    }

    // MARK: - Expected values, derived by hand in GoldenScenario's doc comment

    /// Scheduled basal is filled from the first record (00:00) to the last (23:55 on day 2).
    private let pumpHistoryBasal = (6.0 + 2.0 + 0.5 + 16.0) + (10.0 + 9.0 + 1.0 + (3.0 + 35.0 / 60))
    private let bolusTotal = 26.5

    private func assertGlucose(_ g: GlucoseStatistics?, file: StaticString = #filePath, line: UInt = #line) throws {
        let g = try XCTUnwrap(g, file: file, line: line)
        XCTAssertEqual(g.readingCount, 576, file: file, line: line)
        XCTAssertEqual(g.mean, 145, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(g.percentiles.p50, 125, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(g.standardDeviation, (3_628_800.0 / 575).squareRoot(), accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(g.coefficientOfVariation, (3_628_800.0 / 575).squareRoot() / 145, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(g.gmi, 3.31 + 0.02392 * 145, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(g.minimum, 50, file: file, line: line)
        XCTAssertEqual(g.maximum, 300, file: file, line: line)
        XCTAssertEqual(g.timeInRanges.veryLow, 0.125, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(g.timeInRanges.low, 0.125, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(g.timeInRanges.inRange, 0.375, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(g.timeInRanges.high, 0.25, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(g.timeInRanges.veryHigh, 0.125, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(g.timeInRanges.tightRange, 0.25, accuracy: accuracy, file: file, line: line)
        // GRI: hypo 12.5 + 0.8 × 12.5 = 22.5; hyper 12.5 + 0.5 × 25 = 25; 3 × 22.5 + 1.6 × 25 = 107.5 → capped.
        XCTAssertEqual(g.gri.hypoComponent, 22.5, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(g.gri.hyperComponent, 25, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(g.gri.uncappedScore, 107.5, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(g.gri.score, 100, file: file, line: line)
        XCTAssertEqual(g.gri.zone, .E, file: file, line: line)
        XCTAssertEqual(g.coverage, 1, accuracy: accuracy, file: file, line: line)
    }

    private func assertBoluses(_ i: InsulinStatistics, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(i.bolusUnits, bolusTotal, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(i.manualBolusUnits, 22, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(i.automaticBolusUnits, 2.5, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(i.externalBolusUnits, 2, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(i.bolusCount, 11, file: file, line: line)
        XCTAssertEqual(i.automaticBolusCount, 6, file: file, line: line)
        XCTAssertEqual(i.suspendedDuration, 3600, accuracy: accuracy, file: file, line: line)
    }

    private func assertInsulin(_ i: InsulinStatistics, basal: Double, file: StaticString = #filePath, line: UInt = #line) {
        assertBoluses(i, file: file, line: line)
        XCTAssertEqual(i.basalUnits, basal, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(i.totalUnits, basal + bolusTotal, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(i.averageDailyDose, (basal + bolusTotal) / 2, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(i.basalFraction, basal / (basal + bolusTotal), accuracy: accuracy, file: file, line: line)
    }

    private func assertCarbs(_ c: CarbStatistics, fatProteinEquivalent: Double = 15, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(c.totalGrams, 230, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(c.entryCount, 4, file: file, line: line)
        XCTAssertEqual(c.averagePerEntry, 57.5, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(c.largestEntry, 80, file: file, line: line)
        XCTAssertEqual(c.averageDailyGrams, 115, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(c.fatProteinEquivalentGrams, fatProteinEquivalent, accuracy: accuracy, file: file, line: line)
    }

    // MARK: - Pump-history style data (what the Trio adapter delivers)

    func testSummaryFromPumpHistory() async throws {
        let report = try await goldenReport()
        try assertGlucose(report.summary.glucose)
        assertInsulin(report.summary.insulin, basal: pumpHistoryBasal)
        // eA1c (ADAG): (145 + 46.7) / 28.7; in mmol/mol 10.929 × (eA1c − 2.152).
        XCTAssertEqual(try XCTUnwrap(report.summary.glucose).estimatedA1c, 191.7 / 28.7, accuracy: accuracy)
        XCTAssertEqual(try XCTUnwrap(report.summary.glucose).estimatedA1cMmolMol, 10.929 * (191.7 / 28.7 - 2.152), accuracy: accuracy)
        // Programmed basal: the 1.0 U/h schedule from the first record (00:00) to the last (23:55 on day 2).
        let programmed = 47 + 55.0 / 60
        XCTAssertEqual(report.summary.insulin.programmedBasalUnits ?? 0, programmed, accuracy: accuracy)
        XCTAssertEqual(report.summary.insulin.averageDailyProgrammedBasal ?? 0, programmed / 2, accuracy: accuracy)
        // Temps add 1.0 − 0.5 + 0.67 U, the suspension takes 1.0 U off: a sixth of a unit over the schedule.
        XCTAssertEqual(report.summary.insulin.deliveredBasalFraction ?? 0, pumpHistoryBasal / programmed, accuracy: accuracy)
        XCTAssertEqual(pumpHistoryBasal - programmed, 1.0 / 6, accuracy: accuracy)
        assertCarbs(report.summary.carbs)
        XCTAssertEqual(report.summary.carbs.totalFatGrams, 10)
        XCTAssertEqual(report.summary.carbs.totalProteinGrams, 20)
        XCTAssertFalse(report.validation.hasErrors)
        // The raw history has an unclosed temp basal; it must be reported, and fixed before counting.
        XCTAssertFalse(report.validation.issues(withCode: .insulinBasalOverlap).isEmpty)
    }

    func testDailyBreakdown() async throws {
        let report = try await goldenReport()
        XCTAssertEqual(report.daily.count, 2)
        let day1 = report.daily[0], day2 = report.daily[1]

        XCTAssertEqual(try XCTUnwrap(day1.glucose).mean, 150, accuracy: accuracy)
        XCTAssertEqual(try XCTUnwrap(day1.glucose).timeInRanges.inRange, 0.5, accuracy: accuracy)
        XCTAssertEqual(try XCTUnwrap(day1.glucose).timeInRanges.high, 0.5, accuracy: accuracy)
        XCTAssertEqual(try XCTUnwrap(day2.glucose).mean, 140, accuracy: accuracy)
        XCTAssertEqual(try XCTUnwrap(day2.glucose).timeInRanges.veryLow, 0.25, accuracy: accuracy)
        XCTAssertEqual(try XCTUnwrap(day2.glucose).timeInRanges.veryHigh, 0.25, accuracy: accuracy)

        // Day 1: 22 h scheduled + 2.0 (06–07) + 0.5 (07–08); boluses 18 manual + 2 SMB + 2 external.
        XCTAssertEqual(day1.insulin.basalUnits, 24.5, accuracy: accuracy)
        XCTAssertEqual(day1.insulin.totalUnits, 46.5, accuracy: accuracy)
        // Day 2: suspended 10–11, temp 20:00–20:20 at 3 U/h, schedule filled to the last record at 23:55.
        XCTAssertEqual(day2.insulin.basalUnits, 19 + 1 + (3 + 35.0 / 60), accuracy: accuracy)
        XCTAssertEqual(day2.insulin.bolusUnits, 4.5, accuracy: accuracy)
        // Programmed basal per day: a whole day of schedule, then the schedule up to the last record.
        XCTAssertEqual(day1.insulin.programmedBasalUnits ?? 0, 24, accuracy: accuracy)
        XCTAssertEqual(day2.insulin.programmedBasalUnits ?? 0, 23 + 55.0 / 60, accuracy: accuracy)
        XCTAssertEqual(day2.insulin.suspendedDuration, 3600, accuracy: accuracy)

        XCTAssertEqual(day1.carbs.totalGrams, 180)
        XCTAssertEqual(day1.carbs.entryCount, 3)
        XCTAssertEqual(day2.carbs.totalGrams, 50)
    }

    func testAmbulatoryGlucoseProfile() async throws {
        let agp = try await goldenReport().agp
        XCTAssertEqual(agp.buckets.count, 24)
        // 00:00 bucket: twelve readings at 100 (day 1) and twelve at 50 (day 2).
        let midnight = try XCTUnwrap(agp.buckets[0].percentiles)
        XCTAssertEqual(agp.buckets[0].readingCount, 24)
        XCTAssertEqual(midnight.p50, 75, accuracy: accuracy)
        XCTAssertEqual(midnight.p5, 50, accuracy: accuracy)
        XCTAssertEqual(midnight.p95, 100, accuracy: accuracy)
        XCTAssertEqual(try XCTUnwrap(agp.buckets[12].percentiles).p50, 175, accuracy: accuracy) // 200 and 150
        XCTAssertEqual(try XCTUnwrap(agp.buckets[18].percentiles).p50, 250, accuracy: accuracy) // 200 and 300

        // The same buckets split by range: 00:00 is half very low (50) and half in range (100),
        // 12:00 half high (200) and half in range (150), 18:00 half high (200) and half very high (300).
        let midnightRanges = try XCTUnwrap(agp.buckets[0].timeInRanges)
        XCTAssertEqual(midnightRanges.veryLow, 0.5, accuracy: accuracy)
        XCTAssertEqual(midnightRanges.inRange, 0.5, accuracy: accuracy)
        let noonRanges = try XCTUnwrap(agp.buckets[12].timeInRanges)
        XCTAssertEqual(noonRanges.high, 0.5, accuracy: accuracy)
        XCTAssertEqual(noonRanges.inRange, 0.5, accuracy: accuracy)
        let eveningRanges = try XCTUnwrap(agp.buckets[18].timeInRanges)
        XCTAssertEqual(eveningRanges.high, 0.5, accuracy: accuracy)
        XCTAssertEqual(eveningRanges.veryHigh, 0.5, accuracy: accuracy)
        for bucket in agp.buckets {
            let t = try XCTUnwrap(bucket.timeInRanges)
            XCTAssertEqual(t.veryLow + t.low + t.inRange + t.high + t.veryHigh, 1, accuracy: accuracy)
        }
    }

    func testRangesByPartOfTheDay() async throws {
        // Each six hours holds 72 readings from day 1 and 72 from day 2:
        // night 100 / 50, morning 100 / 60, afternoon 200 / 150, evening 200 / 300.
        let periods = try await goldenReport().dayPeriods
        XCTAssertEqual(periods.map(\.period), [.night, .morning, .afternoon, .evening])
        XCTAssertEqual(periods.map(\.readingCount), [144, 144, 144, 144])
        let t = try periods.map { try XCTUnwrap($0.timeInRanges) }
        XCTAssertEqual(t[0].veryLow, 0.5, accuracy: accuracy)
        XCTAssertEqual(t[0].inRange, 0.5, accuracy: accuracy)
        XCTAssertEqual(t[1].low, 0.5, accuracy: accuracy)
        XCTAssertEqual(t[1].inRange, 0.5, accuracy: accuracy)
        XCTAssertEqual(t[2].inRange, 0.5, accuracy: accuracy)
        XCTAssertEqual(t[2].high, 0.5, accuracy: accuracy)
        XCTAssertEqual(t[3].high, 0.5, accuracy: accuracy)
        XCTAssertEqual(t[3].veryHigh, 0.5, accuracy: accuracy)
    }

    // MARK: - Other sources must give the same answers

    func testNightscoutMatchesWithAndWithoutPaging() async throws {
        for pageSize in [10000, 100, 7] {
            let source = S.nightscoutSource(pageSize: pageSize)
            let schedule = try await source.basalSchedule()
            XCTAssertEqual(schedule?.dailyTotal ?? 0, 24, accuracy: accuracy)
            let report = try await AIDReport.generate(definition, from: source, options: ReportOptions(basalSchedule: schedule), now: S.end)
            try assertGlucose(report.summary.glucose)
            assertInsulin(report.summary.insulin, basal: pumpHistoryBasal)
            assertCarbs(report.summary.carbs)
            XCTAssertFalse(report.validation.hasErrors, "page size \(pageSize)")
        }
    }

    func testNightscoutPagingRequestsEveryPage() async throws {
        let log = RequestLog()
        _ = try await S.nightscoutSource(pageSize: 100, requestLog: log).dataset(in: S.interval)
        // 576 entries in pages of 100 → five full pages and a short sixth.
        let entryRequests = await log.count(containing: "entries.json")
        let treatmentRequests = await log.count(containing: "treatments.json")
        XCTAssertEqual(entryRequests, 6)
        XCTAssertEqual(treatmentRequests, 1)
    }

    func testAppleHealthSamplesMatch() async throws {
        let dataset = TherapyDataset(
            interval: S.interval,
            source: DataSourceInfo(app: .appleHealth, timeZone: S.utc),
            glucose: S.healthGlucose.map(HealthSampleMapper.glucose),
            insulin: S.healthInsulin.map(HealthSampleMapper.insulin),
            carbs: S.healthCarbs.map(HealthSampleMapper.carbs)
        )
        // Health already holds every delivered basal segment, so no schedule is needed.
        let report = ReportBuilder().build(definition, from: dataset, now: S.end)
        try assertGlucose(report.summary.glucose)
        assertInsulin(report.summary.insulin, basal: 48 + 1.0 / 6) // 6 + 2 + 0.5 + 26 + 0 + 9 + 1 + 3⅔
        assertCarbs(report.summary.carbs, fatProteinEquivalent: 0)
        XCTAssertEqual(report.summary.insulin.basalCoverage, 1, accuracy: accuracy)
        XCTAssertNil(report.summary.insulin.programmedBasalUnits, "no schedule, nothing to compare with")
        XCTAssertEqual(report.validation.issues(atLeast: .error), [])
    }

    func testMergedSourcesFillGlucoseWithoutDoubleCounting() async throws {
        // Nightscout lost six hours of CGM; Apple Health has everything, including the same insulin and carbs.
        let outage = DateInterval(start: S.at(day: 0, 6), end: S.at(day: 0, 12))
        let log = RequestLog()
        let nightscout = S.nightscoutSource(pageSize: 10000, requestLog: log, dropGlucose: outage)
        let health = StaticTherapyDataSource(TherapyDataset(
            interval: S.interval,
            source: DataSourceInfo(app: .appleHealth, timeZone: S.utc),
            glucose: S.healthGlucose.map(HealthSampleMapper.glucose),
            insulin: S.healthInsulin.map(HealthSampleMapper.insulin),
            carbs: S.healthCarbs.map(HealthSampleMapper.carbs)
        ))

        let alone = try await AIDReport.generate(definition, from: nightscout, options: options, now: S.end)
        XCTAssertLessThan(try XCTUnwrap(alone.summary.glucose).coverage, 0.9)

        let merged = try await AIDReport.generate(definition, from: MergedTherapyDataSource([nightscout, health]), options: options, now: S.end)
        try assertGlucose(merged.summary.glucose)
        assertInsulin(merged.summary.insulin, basal: pumpHistoryBasal) // Nightscout's insulin, not both
        assertCarbs(merged.summary.carbs)
        XCTAssertEqual(merged.source.name, "Nightscout + Apple Health")

        // Two reports → the treatments list is downloaded once per report, not once per stream.
        let treatmentRequests = await log.count(containing: "treatments.json")
        XCTAssertEqual(treatmentRequests, 2)
    }

    // MARK: - Bad input must not change the answers

    func testDirtyDataGivesTheSameStatisticsAndIsReported() async throws {
        var dirty = S.dataset()
        dirty.glucose += [
            GlucoseReading(date: S.at(day: 0, 0, 50).addingTimeInterval(10), mgdL: 100, sourceID: "g10"), // same id
            GlucoseReading(date: S.at(day: 0, 3, 2), mgdL: 900, sourceID: "bad"), // implausible
            GlucoseReading(date: S.end.addingTimeInterval(3600), mgdL: 120, sourceID: "future"),
        ]
        dirty.insulin += [
            .bolus(at: S.at(day: 0, 7, 30).addingTimeInterval(5), units: 5, sourceID: "b1"), // uploaded twice
            .bolus(at: S.at(day: 1, 12), units: -3, sourceID: "negative"),
        ]
        dirty.carbs += [
            CarbIntake(date: S.at(day: 0, 12, 30).addingTimeInterval(5), grams: 60, sourceID: "c2"), // uploaded twice
            CarbIntake(date: S.at(day: 1, 15), grams: -20, sourceID: "negative-carbs"),
        ]

        let clean = try await goldenReport()
        let report = ReportBuilder(options: options).build(definition, from: dirty, now: S.end)
        XCTAssertEqual(report.summary, clean.summary)
        XCTAssertEqual(report.daily, clean.daily)

        let codes = Set(report.validation.issues.map(\.code))
        for expected: ValidationCode in [.glucoseDuplicate, .glucoseImplausibleValue, .datasetFutureTimestamp,
                                         .insulinDuplicateBolus, .insulinNegative, .carbsDuplicate, .carbsNegative] {
            XCTAssertTrue(codes.contains(expected), "missing \(expected)")
        }
        XCTAssertTrue(report.validation.hasErrors)
    }

    func testMmolDeliveredAsMgdLIsFlaggedNotAveraged() {
        var wrongUnits = S.dataset()
        wrongUnits.glucose = wrongUnits.glucose.map { GlucoseReading(date: $0.date, mgdL: $0.mgdL / GlucoseUnit.mgdLPerMmolL, sourceID: $0.sourceID) }
        let report = ReportBuilder(options: options).build(definition, from: wrongUnits, now: S.end)
        XCTAssertFalse(report.validation.issues(withCode: .glucoseLikelyMmolL).isEmpty)
        XCTAssertTrue(report.validation.hasErrors)
    }

    // MARK: - Time handling

    func testDaysFollowTheSourceTimeZone() {
        // UTC+1: the same 48 hours touch three local days — 23 h, 24 h and 1 h.
        let stockholm = TimeZone(identifier: "Europe/Stockholm")!
        let report = ReportBuilder(options: options).build(definition, from: S.dataset(timeZone: stockholm), now: S.end)
        let dayLengths: [TimeInterval] = report.daily.map { $0.interval.duration }
        XCTAssertEqual(dayLengths, [23 * 3600.0, 24 * 3600.0, 3600.0])
        // First local day holds 00:00–23:00 UTC: 144 readings at 100 and 132 at 200.
        XCTAssertEqual(report.daily[0].glucose?.mean ?? 0, (144.0 * 100 + 132 * 200) / 276, accuracy: accuracy)
        XCTAssertEqual(report.daily.compactMap(\.glucose).map(\.readingCount).reduce(0, +), 576)
        XCTAssertEqual(report.daily.map(\.insulin.totalUnits).reduce(0, +), report.summary.insulin.totalUnits, accuracy: accuracy)
        // Time-of-day buckets shift by one hour: local 00:00 is 23:00 UTC (200 on day 1, 300 on day 2).
        XCTAssertEqual(report.agp.buckets[0].percentiles?.p50 ?? 0, 250, accuracy: accuracy)
    }

    func testWholeDaysOfDataCarryNoPartialDayWarning() async throws {
        // The scenario's data runs from 00:00 on day 1 to 23:55 on day 2: both days are whole.
        let report = try await goldenReport()
        XCTAssertEqual(report.dataSpan, DataSpan(first: S.start, last: S.at(day: 1, 23, 55)))
        XCTAssertFalse(report.isFirstDayPartial)
        XCTAssertFalse(report.isLastDayPartial)
        XCTAssertNil(report.partialDayWarning)
        XCTAssertFalse(MarkdownReportRenderer().render(report).contains("partial"))
    }

    func testRollingRangeWarnsAboutItsPartialDays() async throws {
        // Generated at 10:30 on day 2 for the last 24 hours: data starts at 10:30 on day 1 and
        // stops at 10:25 on day 2, so neither calendar day is whole.
        let now = S.at(day: 1, 10, 30)
        let source = StaticTherapyDataSource(S.dataset())
        let definition = ReportDefinition(range: .day, sections: ReportSection.allCases)
        let report = try await AIDReport.generate(definition, from: source, options: options, now: now)
        XCTAssertEqual(report.interval, DateInterval(start: S.at(day: 0, 10, 30), end: now))
        XCTAssertEqual(report.dataSpan?.first, S.at(day: 0, 10, 30))
        XCTAssertTrue(report.isFirstDayPartial)
        XCTAssertTrue(report.isLastDayPartial)
        let warning = try XCTUnwrap(report.partialDayWarning)
        XCTAssertTrue(warning.hasPrefix("The first and last day are partial: data runs from 2026-01-01 10:30 to 2026-01-02 10:"), warning)

        // Shown on every page with per-day values and on data quality, nowhere else.
        for section in ReportSection.allCases {
            let expected = section.showsDailyValues || section == .dataQuality
            XCTAssertEqual(report.partialDayWarning(for: section) != nil, expected, "\(section)")
        }
        let markdown = MarkdownReportRenderer().render(report)
        XCTAssertTrue(markdown.contains("## Insulin\n\n**Warning:** The first and last day are partial"))
        XCTAssertFalse(markdown.contains("## Settings\n\n**Warning:**"), "settings are not per day")
        XCTAssertTrue(markdown.contains("## Data Quality\n\n**Warning:** The first and last day are partial"))
        XCTAssertFalse(markdown.contains("## Overview\n\n**Warning:**"))
    }

    func testOnlyTheShortEndIsNamed() async throws {
        // From midnight on day 1 to noon on day 2: the first day is whole, the last stops at noon.
        let now = S.at(day: 1, 12)
        let interval = DateInterval(start: S.start, end: now)
        let definition = ReportDefinition(range: .custom(interval), sections: ReportSection.allCases)
        let report = try await AIDReport.generate(definition, from: StaticTherapyDataSource(S.dataset()), options: options, now: now)
        XCTAssertFalse(report.isFirstDayPartial)
        XCTAssertTrue(report.isLastDayPartial)
        XCTAssertTrue(try XCTUnwrap(report.partialDayWarning).hasPrefix("The last day is partial: data ends at 2026-01-02 1"))
    }

    func testPartialDayToleranceIsTenMinutesFromMidnight() throws {
        let stockholm = try XCTUnwrap(TimeZone(identifier: "Europe/Stockholm"))
        let iso = ISO8601DateFormatter()
        func date(_ text: String) throws -> Date { try XCTUnwrap(iso.date(from: text)) }

        // Local midnight in January is 23:00 UTC the day before.
        let whole = DataSpan(first: try date("2026-01-09T23:10:00Z"), last: try date("2026-01-12T22:50:00Z")) // 00:10 … 23:50 local
        XCTAssertFalse(whole.isFirstDayPartial(timeZone: stockholm))
        XCTAssertFalse(whole.isLastDayPartial(timeZone: stockholm))

        let short = DataSpan(first: try date("2026-01-09T23:11:00Z"), last: try date("2026-01-12T22:49:00Z")) // 00:11 … 23:49 local
        XCTAssertTrue(short.isFirstDayPartial(timeZone: stockholm))
        XCTAssertTrue(short.isLastDayPartial(timeZone: stockholm))

        // Data ending exactly at midnight completed the day before.
        let toMidnight = DataSpan(first: try date("2026-01-09T23:00:00Z"), last: try date("2026-01-12T23:00:00Z"))
        XCTAssertFalse(toMidnight.isFirstDayPartial(timeZone: stockholm))
        XCTAssertFalse(toMidnight.isLastDayPartial(timeZone: stockholm))

        // The same instants are an hour from midnight in another time zone.
        XCTAssertTrue(toMidnight.isFirstDayPartial(timeZone: S.utc))

        // Either side of midnight counts: a window from 23:55 to 23:55 is whole days too.
        let justBefore = DataSpan(first: try date("2026-01-09T22:55:00Z"), last: try date("2026-01-12T22:55:00Z")) // 23:55 … 23:55 local
        XCTAssertFalse(justBefore.isFirstDayPartial(timeZone: stockholm))
        XCTAssertFalse(justBefore.isLastDayPartial(timeZone: stockholm))
        XCTAssertEqual(DataSpan.distanceToMidnight(try date("2026-01-09T22:55:00Z"), timeZone: stockholm), 300)
    }

    func testFollowerInAnotherTimeZoneReportsOnTheLoopersClock() async throws {
        // The looper lives in Stockholm (UTC+1); the follower's device is eight hours behind.
        // The scenario's two UTC days, read on the looper's clock, are 01:00 to 01:00.
        let stockholm = try XCTUnwrap(TimeZone(identifier: "Europe/Stockholm"))
        let follower = try XCTUnwrap(TimeZone(identifier: "America/Edmonton"))
        let site = S.nightscoutSource(pageSize: 10000, profileTimeZone: "Europe/Stockholm")
            .usingTimeZone(follower) // what a follower app starts with: its own device time zone

        let profile = try await site.profile()
        XCTAssertEqual(profile.timeZone, stockholm)
        XCTAssertEqual(profile.basalSchedule?.timeZoneIdentifier, "Europe/Stockholm")

        let source = site.usingTimeZone(try XCTUnwrap(profile.timeZone))
        XCTAssertEqual(source.info.timeZone, stockholm)
        let report = try await AIDReport.generate(definition, from: source, options: ReportOptions(basalSchedule: profile.basalSchedule), now: S.end)

        // The totals do not depend on the clock…
        try assertGlucose(report.summary.glucose)
        assertCarbs(report.summary.carbs)
        // …but days, times of day and printed times are the looper's.
        XCTAssertEqual(report.source.timeZone, stockholm)
        let dayLengths: [TimeInterval] = report.daily.map { $0.interval.duration }
        XCTAssertEqual(dayLengths, [23 * 3600.0, 24 * 3600.0, 3600.0])
        XCTAssertEqual(report.agp.buckets[0].percentiles?.p50 ?? 0, 250, accuracy: accuracy) // local 00:00 is 23:00 UTC
        let markdown = MarkdownReportRenderer().render(report)
        XCTAssertTrue(markdown.contains("- **Period:** 2026-01-01 01:00 – 2026-01-03 01:00"))
        XCTAssertTrue(markdown.contains("- **Generated:** 2026-01-03 01:00 (GMT+1)"))
        // 01:00 is an hour from midnight on the looper's clock, so both end days are partial.
        XCTAssertTrue(try XCTUnwrap(report.partialDayWarning).contains("data runs from 2026-01-01 01:00 to 2026-01-03 00:55"))

        // On the follower's clock the same report would have cut the days eight hours off.
        let onFollowerClock = try await AIDReport.generate(definition, from: site, options: ReportOptions(basalSchedule: profile.basalSchedule), now: S.end)
        XCTAssertEqual(onFollowerClock.daily.first?.interval.duration, 7 * 3600) // 17:00 to midnight in Edmonton
    }

    func testRangeEndingInTheFutureOnlyCountsElapsedTime() {
        // Generated at the end of day 1 for a two-day range: day 2 has not happened yet.
        let now = S.at(day: 1, 0)
        let soFar = S.dataset().restricted(to: DateInterval(start: S.start, end: now))
        let raw = TherapyDataset(interval: S.interval, source: soFar.source, glucose: soFar.glucose, insulin: soFar.insulin, carbs: soFar.carbs)
        let report = ReportBuilder(options: options).build(definition, from: raw, now: now)
        XCTAssertEqual(report.summary.glucose?.coverage ?? 0, 1, accuracy: accuracy)
        XCTAssertEqual(report.summary.insulin.days, 1, accuracy: accuracy)
        XCTAssertEqual(report.summary.carbs.averageDailyGrams, 180, accuracy: accuracy)
        XCTAssertEqual(report.daily.count, 1)
        XCTAssertTrue(report.validation.issues(withCode: .glucoseLowCoverage).isEmpty)
    }

    func testNoBasalIsInventedBeforeTheFirstRecord() {
        // The app was installed at the start of day 2: nothing exists for day 1.
        let installed = S.at(day: 1, 0)
        let late = S.dataset().restricted(to: DateInterval(start: installed, end: S.end))
        let raw = TherapyDataset(interval: S.interval, source: late.source, glucose: late.glucose, insulin: late.insulin, carbs: late.carbs)
        let report = ReportBuilder(options: options).build(definition, from: raw, now: S.end)
        XCTAssertEqual(report.daily[0].insulin.totalUnits, 0, accuracy: accuracy)
        XCTAssertEqual(report.daily[1].insulin.basalUnits, 19 + 1 + (3 + 35.0 / 60), accuracy: accuracy)
        XCTAssertNil(report.daily[0].glucose)
    }

    // MARK: - What the reader sees

    func testMarkdownShowsTheComputedNumbers() async throws {
        let markdown = MarkdownReportRenderer().render(try await goldenReport())
        for expected in [
            "# Glucose Report",
            // Overview
            "| Time in range | 37.5% (Below 25.0% · above 37.5%) |",
            "| GRI | 100.0 (Zone E) |",
            "| CV / SD | 54.8% / 79 mg/dL |",
            "| eA1c | 6.7% (49 mmol/mol) |",
            "| Total daily dose | 37.3 U |",
            "| Programmed basal per day | 24.0 U (Basal schedule) |",
            "| Delivered basal per day | 24.0 U (100% of programmed) |",
            // Glucose distribution
            "| Mean | 145 mg/dL |",
            "| GMI | 6.8% |",
            "| Median | 125 mg/dL |",
            "| Time of day | Very low | Low | In range | High | Very high |",
            "| Night (00–06) | 50.0% | 0.0% | 50.0% | 0.0% | 0.0% |",
            "| Morning (06–12) | 0.0% | 50.0% | 50.0% | 0.0% | 0.0% |",
            "| Afternoon (12–18) | 0.0% | 0.0% | 50.0% | 50.0% | 0.0% |",
            "| Evening (18–24) | 0.0% | 0.0% | 0.0% | 50.0% | 50.0% |",
            "| 2026-01-01 | 46.5 U | 24.5 U | 22.0 U | 2.0 U |",
            "| 2026-01-01 | 180 g | 3 | 10 g | 20 g |",
            "Average 115 g per day in 2.0 entries per day (average 58 g per entry, largest 80 g).",
            "Fat/protein carb equivalents: 8 g per day",
            "| Manual | 11.0 U | 83% |",
            "| Automatic (SMB) | 1.2 U | 9% |",
            "5.5 boluses per day, 3.0 of them automatic.",
            "- **CGM:** Dexcom G7",
        ] {
            XCTAssertTrue(markdown.contains(expected), "Markdown is missing: \(expected)")
        }
    }

    func testPagesFollowTheExportMenuOrder() async throws {
        // The export menu lists Summary, Glucose, Carbs, Insulin, each with its charts in the
        // same order as Trio's statistics export.
        XCTAssertEqual(ReportSection.Category.allCases, [.summary, .glucose, .carbs, .insulin])
        XCTAssertEqual(ReportSection.Category.summary.sections, [.overview, .dataQuality])
        XCTAssertEqual(ReportSection.Category.glucose.sections.map(\.menuTitle),
                       ["Distribution", "Glycemia Risk Index", "Percentile (by day)", "Distribution (by day)", "Heatmap (by day)"])
        XCTAssertEqual(ReportSection.Category.carbs.sections.map(\.menuTitle), ["Total Meals"])
        XCTAssertEqual(ReportSection.Category.insulin.sections.map(\.menuTitle), ["Insulin", "Settings", "Bolus Distribution"])
        XCTAssertFalse(ReportDefinition.defaultSections.contains(.therapySettings), "the Settings page is optional")

        // Pages: overview first, the charts in menu order, data quality last.
        let charts = [ReportSection.Category.glucose, .carbs, .insulin].flatMap(\.sections)
        XCTAssertEqual(ReportSection.allCases, [.overview] + charts + [.dataQuality])
        XCTAssertEqual(ReportDefinition.defaultSections, ReportSection.allCases.filter(ReportDefinition.defaultSections.contains))
        XCTAssertEqual(ReportSection.allCases.filter(\.isPerDay), [.glucosePercentileByDay, .glucoseDistributionByDay, .glucoseHeatmapByDay])

        let markdown = MarkdownReportRenderer().render(try await goldenReport())
        let positions = try ReportSection.allCases.map { try XCTUnwrap(markdown.range(of: "## \($0.title)\n")).lowerBound }
        XCTAssertEqual(positions, positions.sorted())
    }

    func testHeatmapShowsEachDaysAverage() async throws {
        // Thursday 1 January averages 150, Friday 2 January 140.
        let report = try await goldenReport()
        var monday = Calendar(identifier: .gregorian)
        monday.timeZone = S.utc
        monday.firstWeekday = 2
        let heatmap = report.dailyGlucoseHeatmap(calendar: monday)
        XCTAssertEqual(heatmap.weeks.count, 1)
        XCTAssertEqual(heatmap.weeks[0].cells.map { $0?.meanMgdL }, [nil, nil, nil, 150, 140, nil, nil])
        XCTAssertEqual(heatmap.days.map(\.coverage), [1, 1])
        XCTAssertEqual(heatmap.days.map(heatmap.band), [.inRange, .inRange])
        XCTAssertTrue(heatmap.lowCoverageDays.isEmpty)

        let markdown = MarkdownReportRenderer().render(report)
        for expected in [
            "## Average Glucose by Day",
            "| Days with data | 2 of 2 |",
            "| Lowest daily average | 140 mg/dL (2026-01-02) |",
            "| Highest daily average | 150 mg/dL (2026-01-01) |",
            "| Daily average (mg/dL) | Days |",
            "| In range (70–180) | 2 |",
            "| High (>180–250) | 0 |",
            "| Very high (>250) | 0 |",
            "| 150 | 140 |",
        ] {
            XCTAssertTrue(markdown.contains(expected), "Markdown is missing: \(expected)")
        }
        XCTAssertFalse(markdown.contains("CGM coverage that day"))
        XCTAssertFalse(markdown.contains("Low (<70)")) // listed only when a day averaged below range
    }

    func testPatientNameIsPrintedOnlyWhenGiven() async throws {
        var report = try await goldenReport()
        XCTAssertFalse(MarkdownReportRenderer().render(report).contains("Patient"))

        report.metadata.patientName = "  Alex Example \n"
        XCTAssertTrue(MarkdownReportRenderer().render(report).contains("- **Patient:** Alex Example\n"))
        let renderer = JSONReportRenderer()
        XCTAssertEqual(try renderer.decode(renderer.render(report)).metadata.patientName, "  Alex Example \n")

        report.metadata.patientName = "   "
        XCTAssertFalse(MarkdownReportRenderer().render(report).contains("Patient"))
    }

    func testShortRangeNames() {
        // The export sheet offers Trio's ranges; a month is the default.
        XCTAssertEqual(ReportRange.presets.map(\.shortName), ["D", "W", "M", "3 M"])
        XCTAssertEqual(ReportDefinition.standard.range, .month)
        XCTAssertEqual(ReportRange.twoWeeks.shortName, "2 W") // still valid in saved presets
        XCTAssertEqual(ReportRange.lastDays(10).shortName, "10 D")
    }

    func testMmolDisplayConvertsOnlyAtTheEdge() {
        let report = ReportBuilder(options: options).build(definition, from: S.dataset(unit: .mmolL), now: S.end)
        XCTAssertEqual(report.summary.glucose?.mean ?? 0, 145, accuracy: accuracy) // stored in mg/dL
        let markdown = MarkdownReportRenderer().render(report)
        XCTAssertTrue(markdown.contains("| Mean | 8.0 mmol/L |")) // 145 / 18.015588
        XCTAssertTrue(markdown.contains("| CV / SD | 54.8% / 4.4 mmol/L |"))
        XCTAssertTrue(markdown.contains("In range (3.9–10.0)"))
    }

    func testDailyCSVRows() async throws {
        let rows = CSVExporter().daily(try await goldenReport()).split(separator: "\n").map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
        XCTAssertEqual(rows.count, 3)
        let header = rows[0]
        func value(_ column: String, day: Int) -> String { rows[day][header.firstIndex(of: column)!] }
        XCTAssertEqual(value("date", day: 1), "2026-01-01")
        XCTAssertEqual(value("readings", day: 1), "288")
        XCTAssertEqual(value("mean_mgdl", day: 1), "150.0")
        XCTAssertEqual(value("in_range_pct", day: 1), "50.0")
        XCTAssertEqual(value("high_pct", day: 1), "50.0")
        XCTAssertEqual(value("tdd_u", day: 1), "46.50")
        XCTAssertEqual(value("basal_u", day: 1), "24.50")
        XCTAssertEqual(value("automatic_bolus_u", day: 1), "2.00")
        XCTAssertEqual(value("carbs_g", day: 1), "180")
        XCTAssertEqual(value("mean_mgdl", day: 2), "140.0")
        XCTAssertEqual(value("very_low_pct", day: 2), "25.0")
        XCTAssertEqual(value("carb_entries", day: 2), "1")
    }

    func testJSONRoundTripKeepsEveryNumber() async throws {
        let report = try await goldenReport()
        let renderer = JSONReportRenderer()
        let decoded = try renderer.decode(renderer.render(report))
        XCTAssertEqual(decoded.summary, report.summary)
        XCTAssertEqual(decoded.daily, report.daily)
        XCTAssertEqual(decoded.agp, report.agp)
        XCTAssertEqual(decoded.validation, report.validation)
    }

    #if canImport(PDFKit) && canImport(Charts)
    @MainActor
    func testPDFPagesCarryTheSameNumbers() async throws {
        guard #available(iOS 16.0, macOS 13.0, *) else { throw XCTSkip("Requires iOS 16 / macOS 13") }
        var report = try await goldenReport()
        report.metadata.patientName = "Alex Example"
        let document = try XCTUnwrap(PDFDocument(data: try PDFReportExporter.render(report)))
        for index in 0 ..< document.pageCount {
            XCTAssertTrue(document.page(at: index)?.string?.contains("Alex Example") ?? false, "page \(index + 1) has no patient name")
        }
        XCTAssertEqual(document.pageCount, ReportSection.allCases.count)

        func text(_ section: ReportSection) throws -> String {
            let index = try XCTUnwrap(report.renderableSections.firstIndex(of: section))
            return try XCTUnwrap(document.page(at: index)?.string)
        }
        let overview = try text(.overview)
        XCTAssertFalse(overview.contains("Golden"), "a preset's name is not printed")
        for expected in ["Glucose Report", "Time in range", "37.5%", "Below 25.0% · above 37.5%", "GRI", "100.0", "Zone E", "CV / SD", "54.8% / 79 mg/dL",
                         "eA1c", "6.7%", "49 mmol/mol", "Total daily dose", "37.3 U", "Programmed basal per day", "Delivered basal per day",
                         "24.0 U", "100% of programmed", "Dexcom G7", "Page 1 of \(ReportSection.allCases.count)"] {
            XCTAssertTrue(overview.contains(expected), "Overview page is missing: \(expected)")
        }
        let distribution = try text(.glucoseDistribution)
        for expected in ["In range (70–180)", "37.5%", "Tight range (70–140)", "By time of day", "Night", "00–06", "Morning", "Afternoon", "Evening", "18–24", "50%"] {
            XCTAssertTrue(distribution.contains(expected), "Distribution page is missing: \(expected)")
        }
        let gri = try text(.glycemiaRiskIndex)
        for expected in ["22.5", "25.0", "107.5", "Zone E", "Zone A (0–20)", "Zone E (>80–100)", "Hypoglycemia component (%)", "Hyperglycemia component (%)"] {
            XCTAssertTrue(gri.contains(expected), "GRI page is missing: \(expected)")
        }
        let heatmap = try text(.glucoseHeatmapByDay)
        for expected in ["Average Glucose by Day", "2 of 2", "150 mg/dL", "2026-01-01", "140 mg/dL", "2026-01-02", "Thu", "Fri", "No data", "In range (70–180)", "High (>180–250)", "Very high (>250)"] {
            XCTAssertTrue(heatmap.contains(expected), "Heatmap page is missing: \(expected)")
        }
        let dose = try text(.insulinTotalDailyDose)
        XCTAssertTrue(dose.contains("37.3 U"))
        XCTAssertTrue(dose.contains("30 min")) // 1 h suspended over two days
        XCTAssertTrue(try text(.carbsTotals).contains("57 g") || (try text(.carbsTotals).contains("58 g"))) // 57.5 average per entry
    }
    #endif
}
