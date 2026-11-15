#if canImport(SwiftUI) && canImport(Charts) && !os(watchOS)
import AIDReportKit
import SwiftUI

/// Shared printable page chrome: title, report name, section/range subtitle, generation time,
/// hardware/software/settings metadata, and a footer. Forced to white background and black text
/// so the export looks the same regardless of the device's appearance.
@available(iOS 16.0, macOS 13.0, *)
public struct ReportPage<Content: View>: View {
    let report: TherapyReport
    let sectionTitle: String
    let categoryTitle: String
    let pageNumber: Int
    let pageCount: Int
    let pageSize: CGSize
    let content: Content

    public init(
        report: TherapyReport,
        sectionTitle: String,
        categoryTitle: String,
        pageNumber: Int,
        pageCount: Int,
        pageSize: CGSize = PDFReportExporter.a4,
        @ViewBuilder content: () -> Content
    ) {
        self.report = report
        self.sectionTitle = sectionTitle
        self.categoryTitle = categoryTitle
        self.pageNumber = pageNumber
        self.pageCount = pageCount
        self.pageSize = pageSize
        self.content = content()
    }

    public init(
        report: TherapyReport,
        section: ReportSection,
        pageNumber: Int,
        pageCount: Int,
        pageSize: CGSize = PDFReportExporter.a4,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            report: report,
            sectionTitle: section.title,
            categoryTitle: section.category.title,
            pageNumber: pageNumber,
            pageCount: pageCount,
            pageSize: pageSize,
            content: content
        )
    }

    private var formatter: ReportFormatter { ReportFormatter(report: report) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            Text(sectionTitle).font(.title3.bold())
            content
            Spacer(minLength: 0)
            footer
        }
        .padding(32)
        .frame(width: pageSize.width, height: pageSize.height, alignment: .topLeading)
        .background(Color.white)
        .foregroundStyle(Color.black)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(report.title)
                .font(.title2.bold())
            if let patientName = report.metadata.printablePatientName {
                Text(patientName).font(.headline)
            }
            Text(verbatim: "\(categoryTitle) · \(report.definition.range.displayName) (\(formatter.period(report.interval)))")
                .font(.subheadline)
                .foregroundStyle(Color.gray)
            Text(String(localized: "Generated \(formatter.dateTimeWithZone(report.generatedAt)) · Source: \(report.source.name) · Units: \(report.displayUnit.rawValue)",
                        bundle: .module, comment: "PDF page subtitle; arguments are a date and time, the data source and the glucose unit"))
                .font(.caption)
                .foregroundStyle(Color.gray)
            if !report.metadata.isEmpty {
                HStack(alignment: .top, spacing: 24) {
                    metadataColumn(String(localized: "Hardware", bundle: .module, comment: "PDF header column: CGM, pump and phone"), report.metadata.hardwareItems)
                    metadataColumn(String(localized: "Software", bundle: .module, comment: "PDF header column: app name, version and build"), report.metadata.softwareItems)
                    metadataColumn(String(localized: "Settings", bundle: .module, comment: "PDF header column: key therapy settings"), report.metadata.settings)
                }
                .padding(.top, 6)
            }
        }
    }

    @ViewBuilder
    private func metadataColumn(_ title: String, _ items: [ReportMetadata.Item]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.bold())
                ForEach(items, id: \.self) { item in
                    Text(verbatim: "\(item.label): \(item.value)").font(.caption2)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(String(localized: "Not a medical device. Discuss therapy changes with your care team.", bundle: .module,
                        comment: "Disclaimer in the PDF footer"))
            Spacer()
            Text(String(localized: "Page \(pageNumber) of \(pageCount)", bundle: .module, comment: "PDF page number footer"))
        }
        .font(.caption2)
        .foregroundStyle(Color.gray)
    }
}
#endif
