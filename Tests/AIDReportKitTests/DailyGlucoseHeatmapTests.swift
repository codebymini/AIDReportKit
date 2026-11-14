import AIDReportKit
import XCTest

final class DailyGlucoseHeatmapTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    private func calendar(firstWeekday: Int) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    /// 2026-01-01 is a Thursday.
    private func day(_ offset: Int) -> Date {
        Date(timeIntervalSince1970: 1_767_225_600 + Double(offset) * 86400)
    }

    /// One reading every five minutes at `mean` for `hours` of the day; `nil` leaves the day empty.
    private func summary(_ offset: Int, mean: Double?, hours: Int = 24) -> DailySummary {
        let interval = DateInterval(start: day(offset), duration: 86400)
        let readings = (mean.map { value in
            (0 ..< hours * 12).map { GlucoseReading(date: day(offset).addingTimeInterval(Double($0) * 300), mgdL: value) }
        }) ?? []
        let dataset = TherapyDataset(interval: interval, source: DataSourceInfo(app: .other, timeZone: utc), glucose: readings)
        return StatsAggregator(timeZone: utc).daily(dataset)[0]
    }

    func testDaysFallIntoWeekRowsUnderTheirWeekday() {
        // Thu 1 Jan … Mon 12 Jan, Monday-first: three week rows.
        let daily = (0 ..< 12).map { summary($0, mean: 100 + Double($0) * 10) }
        let heatmap = DailyGlucoseHeatmap(daily: daily, calendar: calendar(firstWeekday: 2))

        XCTAssertEqual(heatmap.weekdays, [2, 3, 4, 5, 6, 7, 1])
        XCTAssertEqual(heatmap.weekdays.map(DailyGlucoseHeatmap.weekdayName), ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"])
        XCTAssertEqual(heatmap.weeks.map(\.start), [day(-3), day(4), day(11)])
        XCTAssertEqual(heatmap.weeks.map { $0.cells.map { $0?.dayOfMonth } }, [
            [nil, nil, nil, 1, 2, 3, 4],
            [5, 6, 7, 8, 9, 10, 11],
            [12, nil, nil, nil, nil, nil, nil],
        ])
        XCTAssertEqual(heatmap.days.count, 12)
        XCTAssertEqual(heatmap.weeks[0].cells[3]?.meanMgdL ?? 0, 100, accuracy: 1e-9)
        XCTAssertEqual(heatmap.weeks[2].cells[0]?.meanMgdL ?? 0, 210, accuracy: 1e-9)
    }

    func testSundayFirstCalendarsShiftTheColumns() {
        let heatmap = DailyGlucoseHeatmap(daily: [summary(0, mean: 120), summary(1, mean: 130)], calendar: calendar(firstWeekday: 1))
        XCTAssertEqual(heatmap.weekdays.first, 1)
        XCTAssertEqual(heatmap.weeks.count, 1)
        XCTAssertEqual(heatmap.weeks[0].start, day(-4)) // Sunday 28 December
        XCTAssertEqual(heatmap.weeks[0].cells.map { $0?.dayOfMonth }, [nil, nil, nil, nil, 1, 2, nil])
    }

    func testColorBandFollowsTheConsensusCutOffs() {
        // In range is 70–180 inclusive; high is above 180 up to 250; very high is above 250.
        let means: [Double] = [69, 70, 180, 181, 250, 251, 53]
        let heatmap = DailyGlucoseHeatmap(daily: means.enumerated().map { summary($0.offset, mean: $0.element) }, calendar: calendar(firstWeekday: 2))
        XCTAssertEqual(heatmap.thresholds, .consensus)
        XCTAssertEqual(heatmap.days.map(heatmap.band), [.low, .inRange, .inRange, .high, .high, .veryHigh, .low])
        XCTAssertEqual(heatmap.dayCount(in: .inRange), 2)
        XCTAssertEqual(heatmap.dayCount(in: .high), 2)
        XCTAssertEqual(heatmap.dayCount(in: .veryHigh), 1)
        XCTAssertEqual(heatmap.dayCount(in: .low), 2)
        XCTAssertEqual(heatmap.legendBands, [.low, .inRange, .high, .veryHigh])
    }

    func testColorMatchesTheNumberPrintedInTheCell() {
        // 180.4 prints as "180" and 69.6 as "70": both must be green under "In range (70–180)".
        let means: [Double] = [69.4, 69.6, 180.4, 180.6, 250.4, 250.6]
        let daily = means.enumerated().map { summary($0.offset, mean: $0.element) }
        let mgdL = DailyGlucoseHeatmap(daily: daily, unit: .mgdL, calendar: calendar(firstWeekday: 2))
        XCTAssertEqual(mgdL.days.map(mgdL.band), [.low, .inRange, .inRange, .high, .high, .veryHigh])

        // In mmol/L the cut-offs read 3.9, 10.0 and 13.9. 181 mg/dL prints as "10.0" (in range),
        // 182 as "10.1" (high); 251 prints as "13.9" (high), 252 as "14.0" (very high).
        let mmolMeans: [Double] = [69, 70, 181, 182, 251, 252]
        let mmol = DailyGlucoseHeatmap(daily: mmolMeans.enumerated().map { summary($0.offset, mean: $0.element) }, unit: .mmolL, calendar: calendar(firstWeekday: 2))
        XCTAssertEqual(mmolMeans.map { GlucoseUnit.mmolL.format(mgdL: $0) }, ["3.8", "3.9", "10.0", "10.1", "13.9", "14.0"])
        XCTAssertEqual(mmol.days.map(mmol.band), [.low, .inRange, .inRange, .high, .high, .veryHigh])
    }

    func testBandsUseTheReportsOwnThresholds() {
        let tight = GlucoseThresholds(low: 70, high: 140, veryHigh: 200)
        let heatmap = DailyGlucoseHeatmap(daily: [summary(0, mean: 150), summary(1, mean: 210)], thresholds: tight, calendar: calendar(firstWeekday: 2))
        XCTAssertEqual(heatmap.days.map(heatmap.band), [.high, .veryHigh])
        let f = ReportFormatter(unit: .mmolL, timeZone: utc)
        XCTAssertEqual(heatmap.bandLabel(.inRange, f), "In range (3.9–7.8)")
        XCTAssertEqual(heatmap.bandLabel(.low, f), "Low (<3.9)")
    }

    func testSummaryPicksExtremesAndCountsDaysPerBand() {
        let daily = [summary(0, mean: 150), summary(1, mean: nil), summary(2, mean: 181), summary(3, mean: 110), summary(4, mean: 260), summary(5, mean: 180)]
        let heatmap = DailyGlucoseHeatmap(daily: daily, calendar: calendar(firstWeekday: 2))
        XCTAssertEqual(heatmap.days.count, 6)
        XCTAssertEqual(heatmap.daysWithData.count, 5)
        XCTAssertEqual(heatmap.lowest?.day, day(3))
        XCTAssertEqual(heatmap.highest?.day, day(4))
        XCTAssertEqual(heatmap.dayCount(in: .inRange), 3) // 150, 110 and exactly 180
        XCTAssertEqual(heatmap.dayCount(in: .high), 1)
        XCTAssertEqual(heatmap.dayCount(in: .veryHigh), 1)
        // No day averaged below range, so the legend leaves that band out.
        XCTAssertEqual(heatmap.legendBands, [.inRange, .high, .veryHigh])
        // The empty day keeps its place in the calendar, without a color.
        let empty = heatmap.days.first { $0.day == day(1) }
        XCTAssertNotNil(empty)
        XCTAssertNil(empty?.meanMgdL)
        XCTAssertNil(empty.flatMap(heatmap.band))
    }

    func testDaysWithLittleDataAreFlagged() {
        // 6 h of readings is 25% coverage; 18 h is 75%.
        let heatmap = DailyGlucoseHeatmap(daily: [summary(0, mean: 140, hours: 6), summary(1, mean: 140, hours: 18)], calendar: calendar(firstWeekday: 2))
        XCTAssertEqual(heatmap.lowCoverageDays.map(\.day), [day(0)])
        XCTAssertEqual(heatmap.days[0].coverage, 0.25, accuracy: 1e-9)
    }

    func testEmptyReportHasNoRows() {
        let heatmap = DailyGlucoseHeatmap(daily: [], calendar: calendar(firstWeekday: 2))
        XCTAssertTrue(heatmap.weeks.isEmpty)
        XCTAssertNil(heatmap.lowest)
        XCTAssertEqual(heatmap.dayCount(in: .inRange), 0)
    }
}
