@testable import AIDReportKit
import XCTest

final class BasalTimelineTests: XCTestCase {
    func testSupersededTempBasalIsEndedWhenTheNextStarts() {
        let first = InsulinDose.basal(start: t0, end: t0 + minutes(30), ratePerHour: 2)
        let second = InsulinDose.basal(start: t0 + minutes(5), end: t0 + minutes(35), ratePerHour: 0.5)
        let result = BasalTimeline.truncatingOverlaps([second, first])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].end, t0 + minutes(5))
        XCTAssertEqual(result[0].units, 2 * 5 / 60, accuracy: 1e-9)
        XCTAssertEqual(result[1], second)
    }

    func testBolusesAreNotTruncated() {
        let temp = InsulinDose.basal(start: t0, end: t0 + minutes(30), ratePerHour: 1)
        let bolus = InsulinDose.bolus(at: t0 + minutes(10), units: 3)
        let result = BasalTimeline.truncatingOverlaps([temp, bolus])
        XCTAssertEqual(result.first { $0.kind == .bolus }, bolus)
        XCTAssertEqual(result.first { $0.kind == .tempBasal }?.end, t0 + minutes(30))
    }

    func testGapsAreFilledFromSchedule() throws {
        let schedule = try XCTUnwrap(BasalSchedule(entries: [.init(startOffset: 0, ratePerHour: 1)], timeZone: utc))
        let interval = DateInterval(start: t0, duration: 3 * hour)
        let temp = InsulinDose.basal(start: t0 + hour, end: t0 + 2 * hour, ratePerHour: 3)
        let filled = BasalTimeline.fillingGaps([temp], in: interval, with: schedule)
        XCTAssertEqual(BasalTimeline.coverage(filled, in: interval), 1, accuracy: 1e-9)
        XCTAssertEqual(filled.reduce(0) { $0 + $1.units }, 1 + 3 + 1, accuracy: 1e-9)
        XCTAssertEqual(filled.filter { $0.kind == .basal }.count, 2)
    }

    func testScheduleSplitsAtBoundariesAndMidnight() throws {
        let schedule = try XCTUnwrap(BasalSchedule(entries: [
            .init(startOffset: 0, ratePerHour: 0.5),
            .init(startOffset: 6 * hour, ratePerHour: 1.0),
            .init(startOffset: 22 * hour, ratePerHour: 0.8),
        ], timeZone: utc))
        XCTAssertEqual(schedule.rate(at: t0 + 7 * hour), 1.0)
        XCTAssertEqual(schedule.dailyTotal, 0.5 * 6 + 1.0 * 16 + 0.8 * 2, accuracy: 1e-9)

        let doses = schedule.doses(in: DateInterval(start: t0 + 21 * hour, duration: 4 * hour)) // 21:00 → 01:00
        XCTAssertEqual(doses.map(\.start), [t0 + 21 * hour, t0 + 22 * hour, t0 + day])
        XCTAssertEqual(doses.reduce(0) { $0 + $1.units }, 1.0 + 0.8 * 2 + 0.5, accuracy: 1e-9)
    }

    func testStepSeriesFromLoopFollowGraphPoints() {
        // LoopFollow stores start/end dot pairs: (r1, t0) (r1, t1) (r2, t1) (r2, t2)
        let points: [(date: Date, ratePerHour: Double)] = [
            (t0, 1.0), (t0 + hour, 1.0), (t0 + hour, 2.0), (t0 + 2 * hour, 2.0),
        ]
        let doses = BasalTimeline.doses(fromStepSeries: points)
        XCTAssertEqual(doses.reduce(0) { $0 + $1.units }, 3, accuracy: 1e-9)
        XCTAssertEqual(BasalTimeline.coverage(doses, in: DateInterval(start: t0, duration: 2 * hour)), 1, accuracy: 1e-9)
    }
}
