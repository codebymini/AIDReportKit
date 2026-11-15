@testable import AIDReportKit
import XCTest

final class GlucoseStatisticsTests: XCTestCase {
    private let interval = DateInterval(start: t0, duration: day)

    func testMeanSDCoefficientOfVariationAndGMI() throws {
        let stats = try XCTUnwrap(GlucoseStatistics.compute(readings([100, 150, 200]), interval: interval))
        XCTAssertEqual(stats.readingCount, 3)
        XCTAssertEqual(stats.mean, 150, accuracy: 1e-9)
        XCTAssertEqual(stats.standardDeviation, 50, accuracy: 1e-9) // sample SD
        XCTAssertEqual(stats.coefficientOfVariation, 1.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(stats.gmi, 3.31 + 0.02392 * 150, accuracy: 1e-9)
        XCTAssertEqual(stats.estimatedA1c, (150 + 46.7) / 28.7, accuracy: 1e-9) // ≈ 6.85%
        XCTAssertEqual(stats.estimatedA1cMmolMol, 10.929 * ((150 + 46.7) / 28.7 - 2.152), accuracy: 1e-9) // ≈ 51
        XCTAssertEqual(stats.minimum, 100)
        XCTAssertEqual(stats.maximum, 200)
    }

    func testTimeInRangeBoundariesFollowConsensus() throws {
        // very low: 53 | low: 54, 69 | in range: 70, 140, 180 | high: 181, 250 | very high: 251
        let stats = try XCTUnwrap(GlucoseStatistics.compute(readings([53, 54, 69, 70, 140, 180, 181, 250, 251, 120]), interval: interval))
        let tir = stats.timeInRanges
        XCTAssertEqual(tir.veryLow, 0.1, accuracy: 1e-9)
        XCTAssertEqual(tir.low, 0.2, accuracy: 1e-9)
        XCTAssertEqual(tir.inRange, 0.4, accuracy: 1e-9)
        XCTAssertEqual(tir.high, 0.2, accuracy: 1e-9)
        XCTAssertEqual(tir.veryHigh, 0.1, accuracy: 1e-9)
        XCTAssertEqual(tir.tightRange, 0.3, accuracy: 1e-9) // 70, 140, 120
        XCTAssertEqual(tir.veryLow + tir.low + tir.inRange + tir.high + tir.veryHigh, 1, accuracy: 1e-9)
    }

    func testPercentilesInterpolateLinearly() throws {
        let p = try XCTUnwrap(Percentiles(values: [50, 10, 40, 20, 30]))
        XCTAssertEqual(p.p5, 12, accuracy: 1e-9)
        XCTAssertEqual(p.p25, 20, accuracy: 1e-9)
        XCTAssertEqual(p.p50, 30, accuracy: 1e-9)
        XCTAssertEqual(p.p75, 40, accuracy: 1e-9)
        XCTAssertEqual(p.p95, 48, accuracy: 1e-9)
        XCTAssertNil(Percentiles(values: []))
    }

    func testGlycemiaRiskIndexComponentsAndZone() {
        // 1% very low, 2% low, 20% high, 5% very high, 72% in range
        let values = Array(repeating: 40.0, count: 1) + Array(repeating: 60.0, count: 2)
            + Array(repeating: 200.0, count: 20) + Array(repeating: 300.0, count: 5) + Array(repeating: 120.0, count: 72)
        let gri = GlycemiaRiskIndex(values: values)
        XCTAssertEqual(gri.hypoComponent, 1 + 0.8 * 2, accuracy: 1e-9)
        XCTAssertEqual(gri.hyperComponent, 5 + 0.5 * 20, accuracy: 1e-9)
        XCTAssertEqual(gri.score, 3 * 2.6 + 1.6 * 15, accuracy: 1e-9) // 31.8
        XCTAssertEqual(gri.zone, .B)
    }

    func testGRIIsCappedAt100() {
        let gri = GlycemiaRiskIndex(values: Array(repeating: 40, count: 50) + Array(repeating: 300, count: 50))
        XCTAssertGreaterThan(gri.uncappedScore, 100)
        XCTAssertEqual(gri.score, 100)
        XCTAssertEqual(gri.zone, .E)
    }

    func testOnlySensorReadingsCount() throws {
        var data = readings([100, 200])
        data.append(GlucoseReading(date: t0.addingTimeInterval(60), mgdL: 400, kind: .fingerstick))
        let stats = try XCTUnwrap(GlucoseStatistics.compute(data, interval: interval))
        XCTAssertEqual(stats.readingCount, 2)
        XCTAssertNil(GlucoseStatistics.compute([], interval: interval))
    }

    func testCoverageCountsFiveMinuteSlots() {
        let hourInterval = DateInterval(start: t0, duration: hour)
        let dates = (0 ..< 12).filter { ![3, 4, 5].contains($0) }.map { t0.addingTimeInterval(Double($0) * 300) }
        XCTAssertEqual(GlucoseStatistics.coverage(of: dates, in: hourInterval), 9.0 / 12.0, accuracy: 1e-9)

        // 1-minute data does not inflate coverage past 100%.
        let everyMinute = (0 ..< 60).map { t0.addingTimeInterval(Double($0) * 60) }
        XCTAssertEqual(GlucoseStatistics.coverage(of: everyMinute, in: hourInterval), 1, accuracy: 1e-9)
    }

    func testAGPBucketsByLocalTimeOfDay() throws {
        let stockholm = TimeZone(identifier: "Europe/Stockholm")!
        // 23:30 UTC on Jan 1 is 00:30 in Stockholm.
        let reading = GlucoseReading(date: t0.addingTimeInterval(23.5 * hour), mgdL: 111)
        let agp = AGPProfile.compute([reading], timeZone: stockholm, bucketMinutes: 60)
        XCTAssertEqual(agp.buckets.count, 24)
        XCTAssertEqual(agp.buckets[0].readingCount, 1)
        XCTAssertEqual(try XCTUnwrap(agp.buckets[0].percentiles).p50, 111)
        XCTAssertEqual(agp.buckets[23].readingCount, 0)
    }
}

final class InsulinAndCarbStatisticsTests: XCTestCase {
    func testTotalsSplitAndDailyDose() {
        let interval = DateInterval(start: t0, duration: day)
        let doses: [InsulinDose] = [
            .basal(.basal, start: t0, end: t0 + day, ratePerHour: 1, isAutomatic: false),
            .bolus(at: t0 + hour, units: 5),
            .bolus(at: t0 + 2 * hour, units: 2, isAutomatic: true),
            .bolus(at: t0 + 3 * hour, units: 1, isExternal: true),
        ]
        let s = InsulinStatistics.compute(doses, interval: interval)
        XCTAssertEqual(s.basalUnits, 24, accuracy: 1e-9)
        XCTAssertEqual(s.bolusUnits, 8, accuracy: 1e-9)
        XCTAssertEqual(s.manualBolusUnits, 5, accuracy: 1e-9)
        XCTAssertEqual(s.automaticBolusUnits, 2, accuracy: 1e-9)
        XCTAssertEqual(s.externalBolusUnits, 1, accuracy: 1e-9)
        XCTAssertEqual(s.totalUnits, 32, accuracy: 1e-9)
        XCTAssertEqual(s.averageDailyDose, 32, accuracy: 1e-9)
        XCTAssertEqual(s.basalFraction, 0.75, accuracy: 1e-9)
        XCTAssertEqual(s.basalCoverage, 1, accuracy: 1e-9)
    }

    func testBasalCrossingIntervalEdgeIsProrated() {
        let interval = DateInterval(start: t0, duration: day)
        let crossing = InsulinDose.basal(start: t0 - 2 * hour, end: t0 + 2 * hour, ratePerHour: 1)
        XCTAssertEqual(InsulinStatistics.compute([crossing], interval: interval).basalUnits, 2, accuracy: 1e-9)
    }

    func testSuspendDuration() {
        let interval = DateInterval(start: t0, duration: day)
        let suspend = InsulinDose(kind: .suspend, start: t0 + hour, end: t0 + hour + minutes(45), units: 0)
        XCTAssertEqual(InsulinStatistics.compute([suspend], interval: interval).suspendedDuration, minutes(45), accuracy: 1e-9)
    }

    func testProgrammedBasalCountsOnlyWhereThereIsData() throws {
        // 1 U/h until noon, 2 U/h after. Data from 06:00 to 18:00, the loop running 0.5 U/h throughout.
        let schedule = try XCTUnwrap(BasalSchedule(entries: [.init(startOffset: 0, ratePerHour: 1), .init(startOffset: 12 * hour, ratePerHour: 2)], timeZone: utc))
        let window = DateInterval(start: t0 + 6 * hour, end: t0 + 18 * hour)
        let temp = InsulinDose.basal(.tempBasal, start: window.start, end: window.end, ratePerHour: 0.5, isAutomatic: true)
        let interval = DateInterval(start: t0, duration: day)

        let s = InsulinStatistics.compute([temp], interval: interval, schedule: schedule, within: window)
        XCTAssertEqual(s.programmedBasalUnits ?? 0, 6 * 1 + 6 * 2, accuracy: 1e-9) // not 36: no data before 06:00 or after 18:00
        XCTAssertEqual(s.averageDailyProgrammedBasal ?? 0, 18, accuracy: 1e-9)
        XCTAssertEqual(s.basalUnits, 6, accuracy: 1e-9)
        XCTAssertEqual(s.deliveredBasalFraction ?? 0, 6.0 / 18, accuracy: 1e-9)

        XCTAssertNil(InsulinStatistics.compute([temp], interval: interval).programmedBasalUnits)
        XCTAssertNil(InsulinStatistics.compute([temp], interval: interval).deliveredBasalFraction)
    }

    func testCarbsExcludeFatProteinEquivalents() {
        let interval = DateInterval(start: t0, duration: 2 * day)
        let entries = [
            CarbIntake(date: t0 + hour, grams: 40, fatGrams: 20, proteinGrams: 30),
            CarbIntake(date: t0 + 2 * hour, grams: 15, isFatProteinEquivalent: true),
            CarbIntake(date: t0 + day + hour, grams: 60),
        ]
        let s = CarbStatistics.compute(entries, interval: interval)
        XCTAssertEqual(s.totalGrams, 100)
        XCTAssertEqual(s.entryCount, 2)
        XCTAssertEqual(s.averagePerEntry, 50)
        XCTAssertEqual(s.largestEntry, 60)
        XCTAssertEqual(s.averageDailyGrams, 50)
        XCTAssertEqual(s.fatProteinEquivalentGrams, 15)
        XCTAssertEqual(s.totalFatGrams, 20)
        XCTAssertEqual(s.totalProteinGrams, 30)
    }

    func testFatProteinOnlyMealIsNotACarbEntry() {
        // Trio stores a meal logged with fat and protein but no carbs as an entry with 0 g.
        let interval = DateInterval(start: t0, duration: day)
        let entries = [
            CarbIntake(date: t0 + hour, grams: 40),
            CarbIntake(date: t0 + 2 * hour, grams: 0, fatGrams: 25, proteinGrams: 35),
            CarbIntake(date: t0 + 3 * hour, grams: 60),
        ]
        let s = CarbStatistics.compute(entries, interval: interval)
        XCTAssertEqual(s.entryCount, 2)
        XCTAssertEqual(s.averagePerEntry, 50)
        XCTAssertEqual(s.averageDailyEntryCount, 2)
        XCTAssertEqual(s.totalFatGrams, 25, "its fat and protein still count")
        XCTAssertEqual(s.totalProteinGrams, 35)
    }

    func testDailyBucketsAreClippedToTheInterval() {
        let interval = DateInterval(start: t0 + 12 * hour, duration: 2 * day) // noon to noon, 3 calendar days
        let aggregator = StatsAggregator(timeZone: utc)
        let days = aggregator.dayIntervals(covering: interval)
        XCTAssertEqual(days.count, 3)
        XCTAssertEqual(days[0].interval.duration, 12 * hour)
        XCTAssertEqual(days[1].interval.duration, day)
        XCTAssertEqual(days[2].interval.duration, 12 * hour)
    }
}
