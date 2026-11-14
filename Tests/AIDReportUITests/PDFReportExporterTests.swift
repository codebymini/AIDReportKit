#if canImport(SwiftUI) && canImport(Charts) && !os(watchOS)
import AIDReportKit
import AIDReportUI
import AIDReportTesting
import CoreGraphics
#if canImport(PDFKit)
import PDFKit
#endif
import XCTest

final class PDFReportExporterTests: XCTestCase {
    @MainActor
    func testRendersOnePagePerRenderableSection() throws {
        guard #available(iOS 16.0, macOS 13.0, *) else { throw XCTSkip("Requires iOS 16 / macOS 13") }

        let generator = SyntheticTherapyGenerator(days: 14)
        let options = ReportOptions(metadata: ReportMetadata(
            appName: "Trio", appVersion: "0.6.0", cgm: "Dexcom G7", pump: "Omnipod DASH", device: "iPhone 16",
            settings: [.init("Closed loop", "On"), .init("SMB", "On"), .init("Dynamic ISF", "Off")]
        ))
        let definition = ReportDefinition(name: "Endo visit", range: .twoWeeks, sections: ReportSection.allCases)
        let report = ReportBuilder(options: options).build(definition, from: generator.makeDataset(), now: generator.interval.end)

        let data = try PDFReportExporter.render(report)
        let document = try XCTUnwrap(CGDataProvider(data: data as CFData).flatMap(CGPDFDocument.init))
        XCTAssertEqual(document.numberOfPages, report.renderableSections.count)

        let page = try XCTUnwrap(document.page(at: 1))
        XCTAssertEqual(page.getBoxRect(.mediaBox).size.width, PDFReportExporter.a4.width, accuracy: 0.5)

        // Set AIDREPORT_PDF_OUTPUT=/path/sample.pdf to inspect the rendering.
        if let output = ProcessInfo.processInfo.environment["AIDREPORT_PDF_OUTPUT"] {
            try data.write(to: URL(fileURLWithPath: output))
        }
    }

    /// Three months is 14 week rows: the calendar, its legend and the footnote must all stay on the page.
    @MainActor
    func testHeatmapFitsThreeMonthsOnOnePage() throws {
        guard #available(iOS 16.0, macOS 13.0, *) else { throw XCTSkip("Requires iOS 16 / macOS 13") }
        let utc = TimeZone(identifier: "UTC")!
        let start = Date(timeIntervalSince1970: 1_767_225_600) // Thursday 2026-01-01
        let interval = DateInterval(start: start, duration: 90 * 86400)

        // Day n averages 80 + 2n mg/dL; day 10 has no data; day 20 has only 6 hours of readings.
        var readings: [GlucoseReading] = []
        for day in 0 ..< 90 where day != 10 {
            let count = day == 20 ? 72 : 288
            for slot in 0 ..< count {
                readings.append(GlucoseReading(date: start.addingTimeInterval(Double(day) * 86400 + Double(slot) * 300), mgdL: 80 + Double(day) * 2))
            }
        }
        let dataset = TherapyDataset(interval: interval, source: DataSourceInfo(app: .trio, timeZone: utc), glucose: readings)
        let definition = ReportDefinition(range: .custom(interval), sections: [.glucoseHeatmapByDay])
        let options = ReportOptions(metadata: ReportMetadata(
            patientName: "Alex Example", appName: "Trio", appVersion: "0.6.0", cgm: "Dexcom G7", pump: "Omnipod DASH", device: "iPhone 16",
            settings: [.init("Closed loop", "On"), .init("SMB", "On"), .init("Dynamic ISF", "Off")]
        ))
        let report = ReportBuilder(options: options).build(definition, from: dataset, now: interval.end)

        let heatmap = report.dailyGlucoseHeatmap()
        XCTAssertGreaterThanOrEqual(heatmap.weeks.count, 13)
        XCTAssertEqual(heatmap.daysWithData.count, 89)
        XCTAssertEqual(heatmap.lowCoverageDays.count, 1)
        // 80–180 on days 0–50 (one of them empty), 182–250 on days 51–85, 252–258 on days 86–89.
        XCTAssertEqual(heatmap.dayCount(in: .inRange), 50)
        XCTAssertEqual(heatmap.dayCount(in: .high), 35)
        XCTAssertEqual(heatmap.dayCount(in: .veryHigh), 4)

        let data = try PDFReportExporter.render(report)
        if let output = ProcessInfo.processInfo.environment["AIDREPORT_HEATMAP_PDF_OUTPUT"] {
            try data.write(to: URL(fileURLWithPath: output))
        }
        #if canImport(PDFKit)
        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(document.pageCount, 1)
        let text = try XCTUnwrap(document.page(at: 0)?.string)
        // First and last day, the flagged day, the legend, the footnote and the footer are all drawn.
        for expected in ["89 of 90", "80 mg/dL", "258 mg/dL", "120*", "In range (70–180)", "High (>180–250)", "Very high (>250)", "No data",
                         "Under 50% CGM coverage that day.", "Page 1 of 1"] {
            XCTAssertTrue(text.contains(expected), "Heatmap page is missing: \(expected)")
        }
        #endif
    }

    /// A range that starts and ends mid-day prints the partial-day warning on per-day pages only.
    @MainActor
    func testPartialDayWarningIsPrintedOnDailyPages() throws {
        guard #available(iOS 16.0, macOS 13.0, *) else { throw XCTSkip("Requires iOS 16 / macOS 13") }
        let generator = SyntheticTherapyGenerator(days: 14)
        // 14:53 on day 2 to 14:53 on day 9: a rolling week inside the generated fortnight.
        let start = generator.interval.start.addingTimeInterval(86400 + 14 * 3600 + 53 * 60)
        let interval = DateInterval(start: start, duration: 7 * 86400)
        let dataset = generator.makeDataset(app: .trio).restricted(to: interval)
        let sections: [ReportSection] = [.overview, .glucoseHeatmapByDay, .insulinTotalDailyDose, .dataQuality]
        let report = ReportBuilder().build(ReportDefinition(range: .custom(interval), sections: sections), from: dataset, now: interval.end)
        XCTAssertTrue(report.isFirstDayPartial)
        XCTAssertTrue(report.isLastDayPartial)

        let data = try PDFReportExporter.render(report)
        if let output = ProcessInfo.processInfo.environment["AIDREPORT_WARNING_PDF_OUTPUT"] {
            try data.write(to: URL(fileURLWithPath: output))
        }
        #if canImport(PDFKit)
        let document = try XCTUnwrap(PDFDocument(data: data))
        let pages = (0 ..< document.pageCount).map { document.page(at: $0)?.string ?? "" }
        XCTAssertEqual(pages.count, 4)
        // PDF text extraction breaks lines, so compare without whitespace.
        let squeezed = pages.map { $0.filter { !$0.isWhitespace } }
        let warning = "Thefirstandlastdayarepartial:dataruns"
        XCTAssertFalse(squeezed[0].contains(warning), "overview")
        XCTAssertTrue(squeezed[1].contains(warning), "heatmap")
        XCTAssertTrue(squeezed[2].contains(warning), "total daily dose")
        XCTAssertTrue(squeezed[3].contains(warning), "data quality")
        // The data is on UTC. Whatever clock this machine keeps, the first bar is 2 January and
        // the header names the report's time zone.
        XCTAssertTrue(pages[2].contains("2 Jan"), "day axis should be labelled on the report's clock")
        XCTAssertFalse(pages[2].contains("1 Jan"))
        XCTAssertTrue(pages[2].contains("Generated 2026-01-09 14:53 (GMT)"))
        #endif
    }

    func testDefaultFileName() {
        let generator = SyntheticTherapyGenerator(days: 1)
        let report = ReportBuilder().build(.standard, from: generator.makeDataset(app: .trio), now: generator.interval.end)
        XCTAssertEqual(PDFReportExporter.defaultFileName(for: report), "Trio-Statistics-20260102_000000")
    }
}
#endif
