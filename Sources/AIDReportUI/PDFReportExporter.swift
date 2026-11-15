#if canImport(SwiftUI) && canImport(Charts) && !os(watchOS)
import AIDReportKit
import CoreGraphics
import Foundation
import SwiftUI

/// Renders SwiftUI pages into a single multi-page PDF, one page per view.
///
/// Use `render(_ report:)` for the built-in pages, or `render(_ pages:)` to supply your own
/// (e.g. Trio's existing statistics charts) wrapped in `ReportPage` for consistent chrome.
@available(iOS 16.0, macOS 13.0, *)
public enum PDFReportExporter {
    /// A4 in points at 72 dpi (210 × 297 mm).
    public static let a4 = CGSize(width: 595.28, height: 841.89)
    /// US Letter in points.
    public static let letter = CGSize(width: 612, height: 792)

    public enum ExportError: LocalizedError {
        case noPages
        case renderingFailed
        case fileWriteFailed(Error)

        public var errorDescription: String? {
            switch self {
            case .noPages:
                return String(localized: "The report has no pages to export.", bundle: .module, comment: "Export error")
            case .renderingFailed:
                return String(localized: "Could not render the PDF content.", bundle: .module, comment: "Export error")
            case let .fileWriteFailed(error):
                return String(localized: "Failed to write PDF file: \(error.localizedDescription)", bundle: .module,
                              comment: "Export error; the argument is the system error message")
            }
        }
    }

    /// The built-in page for each renderable section of `report`.
    @MainActor
    public static func pages(for report: TherapyReport, pageSize: CGSize = a4) -> [AnyView] {
        let sections = report.renderableSections
        return sections.enumerated().map { index, section in
            AnyView(
                ReportPage(report: report, section: section, pageNumber: index + 1, pageCount: sections.count, pageSize: pageSize) {
                    ReportSectionView(section: section, report: report)
                }
            )
        }
    }

    @MainActor
    public static func render(_ report: TherapyReport, pageSize: CGSize = a4) throws -> Data {
        try render(pages(for: report, pageSize: pageSize), pageSize: pageSize)
    }

    /// Renders `pages` at `pageSize`, in order, always in light appearance for print.
    ///
    /// A fresh `ImageRenderer` is built per page because its `content` can only be reassigned to
    /// the same concrete type; all pages draw into one shared PDF context.
    @MainActor
    public static func render(_ pages: [AnyView], pageSize: CGSize = a4) throws -> Data {
        guard !pages.isEmpty else { throw ExportError.noPages }

        let pdfData = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else { throw ExportError.renderingFailed }

        for page in pages {
            let renderer = ImageRenderer(
                content: page
                    .frame(width: pageSize.width, height: pageSize.height)
                    .environment(\.colorScheme, .light)
            )
            renderer.proposedSize = ProposedViewSize(pageSize)
            renderer.render { _, draw in
                context.beginPDFPage(nil)
                draw(context)
                context.endPDFPage()
            }
        }
        context.closePDF()
        return pdfData as Data
    }

    /// Renders and writes `<directory>/<fileName>.pdf`, returning the URL (e.g. for a share sheet).
    @MainActor
    public static func export(
        _ report: TherapyReport,
        fileName: String? = nil,
        directory: URL = FileManager.default.temporaryDirectory,
        pageSize: CGSize = a4
    ) throws -> URL {
        let data = try render(report, pageSize: pageSize)
        let url = directory.appendingPathComponent(fileName ?? defaultFileName(for: report)).appendingPathExtension("pdf")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ExportError.fileWriteFailed(error)
        }
        return url
    }

    /// `<Source>-Glucose-Report-yyyyMMdd_HHmmss`, after the report's title
    public static func defaultFileName(for report: TherapyReport) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = report.source.timeZone
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let name = report.source.name.replacingOccurrences(of: " ", with: "")
        return "\(name)-Glucose-Report-\(formatter.string(from: report.generatedAt))"
    }
}
#endif
