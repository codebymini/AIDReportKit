import AIDReportKit
import AIDReportTesting
import XCTest

private struct FailingSource: TherapyDataSource {
    struct Failure: Error {}
    var info = DataSourceInfo(app: .other, name: "Broken")
    func glucose(in interval: DateInterval) async throws -> [GlucoseReading] { throw Failure() }
    func insulin(in interval: DateInterval) async throws -> [InsulinDose] { throw Failure() }
    func carbs(in interval: DateInterval) async throws -> [CarbIntake] { throw Failure() }
}

final class MergeTests: XCTestCase {
    private let interval = DateInterval(start: t0, duration: 2 * hour)

    private func source(_ name: String, glucose: [GlucoseReading] = [], insulin: [InsulinDose] = [], carbs: [CarbIntake] = []) -> StaticTherapyDataSource {
        StaticTherapyDataSource(TherapyDataset(
            interval: interval,
            source: DataSourceInfo(app: .other, name: name, timeZone: utc),
            glucose: glucose, insulin: insulin, carbs: carbs
        ))
    }

    func testGlucoseGapIsFilledWithoutDuplicates() async throws {
        let all = readings(Array(repeating: 110, count: 24)) // 2 h of 5-minute readings
        let nightscout = source("Nightscout", glucose: all.filter { $0.date < t0 + hour - 1 })
        // Health timestamps are a few seconds off, as when two apps store the same reading.
        let health = source("Apple Health", glucose: all.map { GlucoseReading(date: $0.date + 7, mgdL: $0.mgdL) })

        let merged = MergedTherapyDataSource([nightscout, health])
        let glucose = try await merged.glucose(in: interval)
        XCTAssertEqual(glucose.count, 24)
        XCTAssertEqual(merged.info.name, "Nightscout + Apple Health")
    }

    func testInsulinComesWholeFromFirstNonEmptySource() async throws {
        let primary = source("Primary")
        let secondary = source("Secondary", insulin: [.bolus(at: t0, units: 1)])
        let insulin = try await MergedTherapyDataSource([primary, secondary]).insulin(in: interval)
        XCTAssertEqual(insulin.map(\.units), [1])
    }

    func testBasalGapFillClipsToUncoveredTime() async throws {
        let primary = source("Primary", insulin: [.basal(start: t0, end: t0 + hour, ratePerHour: 1)])
        let secondary = source("Secondary", insulin: [.basal(start: t0, end: t0 + 2 * hour, ratePerHour: 1)])
        let merged = MergedTherapyDataSource([primary, secondary], insulin: .fillGaps(window: 60))
        let insulin = try await merged.insulin(in: interval)
        XCTAssertEqual(insulin.reduce(0) { $0 + $1.units }, 2, accuracy: 1e-9)
        XCTAssertEqual(BasalTimeline.coverage(insulin, in: interval), 1, accuracy: 1e-9)
    }

    func testFailingSourceIsSkippedUnlessAllFail() async throws {
        let good = source("Good", glucose: readings([100]))
        let glucose = try await MergedTherapyDataSource([FailingSource(), good]).glucose(in: interval)
        XCTAssertEqual(glucose.count, 1)

        do {
            _ = try await MergedTherapyDataSource([FailingSource(), FailingSource()]).glucose(in: interval)
            XCTFail("Expected an error when every source fails")
        } catch {}
    }
}
