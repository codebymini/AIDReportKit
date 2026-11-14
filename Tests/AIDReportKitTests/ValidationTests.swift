import AIDReportKit
import AIDReportTesting
import XCTest

final class ValidationTests: XCTestCase {
    private let now = t0 + day

    private func codes(_ data: TherapyDataset, _ configuration: ValidationConfiguration = ValidationConfiguration()) -> [ValidationCode] {
        DatasetValidator(configuration: configuration).validate(data, now: now).issues.map(\.code)
    }

    func testMmolDeliveredAsMgdLIsAnError() {
        let report = DatasetValidator().validate(dataset(glucose: readings([5.5, 6.1, 7.8, 8.2])), now: now)
        XCTAssertTrue(report.hasErrors)
        XCTAssertFalse(report.issues(withCode: .glucoseLikelyMmolL).isEmpty)
    }

    func testImplausibleGlucose() {
        XCTAssertTrue(codes(dataset(glucose: readings([120, 900, 130]))).contains(.glucoseImplausibleValue))
    }

    func testDuplicatesBySourceIDAndByTimeAndValue() {
        let sameID = [GlucoseReading(date: t0, mgdL: 100, sourceID: "a"), GlucoseReading(date: t0 + 300, mgdL: 105, sourceID: "a")]
        let sameTime = [GlucoseReading(date: t0, mgdL: 100), GlucoseReading(date: t0 + 10, mgdL: 100)]
        XCTAssertEqual(codes(dataset(glucose: sameID)).filter { $0 == .glucoseDuplicate }.count, 1)
        XCTAssertEqual(codes(dataset(glucose: sameTime)).filter { $0 == .glucoseDuplicate }.count, 1)
        // One-minute Libre readings are not duplicates.
        let libre = (0 ..< 5).map { GlucoseReading(date: t0 + Double($0) * 60, mgdL: 100) }
        XCTAssertFalse(codes(dataset(glucose: libre)).contains(.glucoseDuplicate))
    }

    func testGapsAndLowCoverage() {
        let interval = DateInterval(start: t0, duration: 2 * hour)
        let data = dataset(interval, glucose: readings(Array(repeating: 110, count: 6))) // first 30 minutes only
        let found = DatasetValidator().validate(data, now: t0 + 2 * hour).issues
        XCTAssertTrue(found.contains { $0.code == .glucoseGap && $0.message.contains("last") })
        XCTAssertTrue(found.contains { $0.code == .glucoseLowCoverage })
    }

    func testRapidChangeIsFlagged() {
        XCTAssertTrue(codes(dataset(glucose: readings([100, 160]))).contains(.glucoseRateOfChange))
    }

    func testFutureTimestampsAreErrors() {
        let data = dataset(DateInterval(start: t0, duration: 2 * day), glucose: [GlucoseReading(date: now + hour, mgdL: 100)])
        XCTAssertTrue(codes(data).contains(.datasetFutureTimestamp))
    }

    func testInsulinChecks() {
        let doses: [InsulinDose] = [
            .bolus(at: t0, units: -1),
            .bolus(at: t0 + hour, units: 40),
            .basal(start: t0, end: t0 + minutes(30), ratePerHour: 1),
            .basal(start: t0 + minutes(10), end: t0 + minutes(40), ratePerHour: 15),
        ]
        let found = codes(dataset(insulin: doses))
        XCTAssertTrue(found.contains(.insulinNegative))
        XCTAssertTrue(found.contains(.insulinBolusAboveMax))
        XCTAssertTrue(found.contains(.insulinBasalOverlap))
        XCTAssertTrue(found.contains(.insulinBasalRateAboveMax))
        XCTAssertTrue(found.contains(.insulinLowBasalCoverage))
    }

    func testCarbChecks() {
        let entries = [
            CarbIntake(date: t0, grams: -5),
            CarbIntake(date: t0 + hour, grams: 400),
            CarbIntake(date: t0 + 2 * hour, grams: 30, sourceID: "x"),
            CarbIntake(date: t0 + 3 * hour, grams: 30, sourceID: "x"),
        ]
        let found = codes(dataset(carbs: entries))
        XCTAssertTrue(found.contains(.carbsNegative))
        XCTAssertTrue(found.contains(.carbsAboveMax))
        XCTAssertTrue(found.contains(.carbsDuplicate))
    }

    func testIssuesAreCappedPerCode() {
        var configuration = ValidationConfiguration()
        configuration.maximumIssuesPerCode = 3
        let found = codes(dataset(glucose: readings(Array(repeating: 900, count: 10))), configuration)
        XCTAssertEqual(found.filter { $0 == .glucoseImplausibleValue }.count, 3)
        XCTAssertTrue(found.contains(.validationTruncated))
    }

    func testErrorsSortFirst() {
        let report = DatasetValidator().validate(dataset(glucose: readings([900, 100])), now: now)
        XCTAssertEqual(report.issues.first?.severity, .error)
    }

    func testSyntheticDataValidatesCleanly() {
        let generator = SyntheticTherapyGenerator(days: 14)
        let report = DatasetValidator().validate(generator.makeDataset(), now: generator.interval.end)
        XCTAssertEqual(report.issues(atLeast: .warning), [])
    }
}

final class SanitizerTests: XCTestCase {
    func testRemovesBadRecordsAndNormalizesBasal() throws {
        let raw = dataset(
            glucose: [
                GlucoseReading(date: t0, mgdL: 100, sourceID: "a"),
                GlucoseReading(date: t0 + 5, mgdL: 100, sourceID: "a"),
                GlucoseReading(date: t0 + 300, mgdL: 900),
                GlucoseReading(date: t0 + 2 * day, mgdL: 120),
            ],
            insulin: [
                .bolus(at: t0 + hour, units: 2, sourceID: "b"),
                .bolus(at: t0 + hour + 5, units: 2, sourceID: "b"),
                .bolus(at: t0 + 2 * hour, units: -1),
                .basal(start: t0, end: t0 + minutes(30), ratePerHour: 2),
                .basal(start: t0 + minutes(5), end: t0 + minutes(35), ratePerHour: 2),
            ],
            carbs: [CarbIntake(date: t0 + hour, grams: -3), CarbIntake(date: t0 + hour, grams: 30)]
        )
        let schedule = try XCTUnwrap(BasalSchedule(entries: [.init(startOffset: 0, ratePerHour: 1)], timeZone: utc))
        let clean = DatasetSanitizer(basalSchedule: schedule).sanitize(raw, now: t0 + day)

        XCTAssertEqual(clean.glucose.map(\.mgdL), [100])
        XCTAssertEqual(clean.insulin.filter { $0.kind == .bolus }.map(\.units), [2])
        XCTAssertEqual(clean.carbs.map(\.grams), [30])
        // Records span 00:00–01:00, so the schedule fills only that hour.
        let basal = clean.insulin.filter(\.isBasalLike)
        XCTAssertEqual(BasalTimeline.coverage(basal, in: DateInterval(start: t0, duration: hour)), 1, accuracy: 1e-6)
        XCTAssertEqual(BasalTimeline.coverage(basal, in: clean.interval), 1.0 / 24, accuracy: 1e-6)
        let tempHours: Double = 35.0 / 60 // two overlapping 2 U/h temps cover 00:00–00:35
        let expected: Double = 2 * tempHours + 1 * (1 - tempHours)
        let total = basal.reduce(0.0) { $0 + $1.units }
        XCTAssertEqual(total, expected, accuracy: 1e-6)
    }
}
