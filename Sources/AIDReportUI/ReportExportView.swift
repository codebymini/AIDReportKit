#if canImport(SwiftUI) && canImport(Charts) && !os(watchOS)
import AIDReportKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Report builder sheet shared by Loop, Trio and LoopFollow.
///
/// Laid out like Trio's statistics export menu: one segmented range, then an "Include" list where
/// each category (Summary, Glucose, Carbs, Insulin) is a row that expands on tap to show its
/// charts, each with its own toggle. Every enabled entry becomes one PDF page. Selections can be saved as a named
/// preset. Export asks for the patient name (remembered between exports), builds the PDF and
/// opens the share sheet. Hosts supply only how to build the report, and optionally their own
/// sheet background.
///
/// ```swift
/// .sheet(isPresented: $showExport) {
///     ReportExportView(presetStore: JSONFileReportPresetStore.applicationSupport()) { definition in
///         try await AIDReport.generate(definition, from: source, options: options)
///     }
/// }
/// ```
@available(iOS 16.0, macOS 13.0, *)
public struct ReportExportView: View {
    public typealias ReportProvider = (ReportDefinition) async throws -> TherapyReport

    /// How far chart rows are indented under their category's row.
    private static let chartRowInset: CGFloat = 20

    private let title: String
    private let ranges: [ReportRange]
    private let presetStore: (any ReportPresetStore)?
    private let background: AnyShapeStyle?
    private let makeReport: ReportProvider

    @Environment(\.dismiss) private var dismiss
    /// The last patient name used, so the prompt shown on each export comes prefilled.
    @AppStorage("AIDReportKit.patientName") private var patientName = ""
    @State private var patientNameInput = ""
    @State private var isAskingPatientName = false
    @State private var range: ReportRange
    @State private var selected = Set(ReportDefinition.defaultSections)
    /// Categories currently expanded to show their charts.
    @State private var expanded: Set<ReportSection.Category> = []
    @State private var presets: [ReportPreset] = []
    @State private var isExporting = false
    @State private var exportedFile: ExportedFile?
    @State private var shareFile: ExportedFile?
    @State private var errorMessage: String?
    @State private var isNamingPreset = false
    @State private var presetName = ""

    /// - Parameters:
    ///   - ranges: The ranges offered, shortest first. A host that keeps less history than the
    ///     longest preset passes `ReportRange.presets(within:)`. A month is preselected when
    ///     offered, otherwise the longest range.
    ///   - background: The host's own sheet background (e.g. Trio's gradient); the standard
    ///     grouped form background when `nil`.
    public init(
        title: String? = nil,
        ranges: [ReportRange] = ReportRange.presets,
        presetStore: (any ReportPresetStore)? = nil,
        background: (any ShapeStyle)? = nil,
        makeReport: @escaping ReportProvider
    ) {
        self.title = title ?? String(localized: "Export PDF", bundle: .module, comment: "Title of the report export sheet")
        self.ranges = ranges.isEmpty ? ReportRange.presets : ranges
        _range = State(initialValue: self.ranges.contains(.month) ? .month : self.ranges[self.ranges.count - 1])
        self.presetStore = presetStore
        self.background = background.map { AnyShapeStyle($0) }
        self.makeReport = makeReport
    }

    /// What will actually be exported: selected and available for the current range, in on-screen
    /// order, which is also the PDF page order.
    private var definition: ReportDefinition {
        ReportDefinition(range: range, sections: ReportSection.allCases.filter { selected.contains($0) && isAvailable($0) })
    }

    public var body: some View {
        NavigationStack {
            Form {
                if !presets.isEmpty {
                    savedReportsSection
                }
                rangeSection
                includeSection
                actionsSection
            }
            .scrollContentBackground(background == nil ? .automatic : .hidden)
            .background(background ?? AnyShapeStyle(.clear))
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", bundle: .module, comment: "Closes the export sheet or a prompt without doing anything")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isExporting {
                        ProgressView()
                    } else {
                        Button(String(localized: "Export", bundle: .module, comment: "Builds the report and creates the PDF")) {
                            // Confirm the patient name on every export, prefilled with the last one.
                            patientNameInput = patientName
                            isAskingPatientName = true
                        }
                        .disabled(definition.sections.isEmpty)
                    }
                }
            }
            .alert(String(localized: "Save Preset", bundle: .module, comment: "Title of the dialog that names a new preset"), isPresented: $isNamingPreset) {
                TextField(String(localized: "Preset name", bundle: .module, comment: "Placeholder for the preset name field"), text: $presetName)
                Button(String(localized: "Cancel", bundle: .module, comment: "Closes the export sheet or a prompt without doing anything"), role: .cancel) {}
                Button(String(localized: "Save", bundle: .module, comment: "Saves the preset"), action: savePreset)
            } message: {
                Text(String(localized: "Saves the current range and chart selection for reuse.", bundle: .module, comment: "Explains what a report preset stores"))
            }
            .alert(String(localized: "Patient Name", bundle: .module, comment: "Title of the prompt shown before each export"), isPresented: $isAskingPatientName) {
                TextField(String(localized: "Name", bundle: .module, comment: "Placeholder for the patient name field"), text: $patientNameInput)
                #if os(iOS)
                    .textContentType(.name)
                    .textInputAutocapitalization(.words)
                #endif
                Button(String(localized: "Cancel", bundle: .module, comment: "Closes the export sheet or a prompt without doing anything"), role: .cancel) {}
                Button(String(localized: "Export", bundle: .module, comment: "Builds the report and creates the PDF")) {
                    patientName = patientNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    export()
                }
            } message: {
                Text(String(localized: "Shown in the report header. Leave blank to omit.", bundle: .module, comment: "Explains the patient name prompt"))
            }
            .onAppear(perform: loadPresets)
            .onDisappear(perform: removeExportedFile)
            #if canImport(UIKit)
            .sheet(item: $shareFile) { file in
                ActivityView(items: [file.url])
            }
            #endif
        }
    }

    // MARK: - Saved reports

    private var savedReportsSection: some View {
        Section(String(localized: "Saved Reports", bundle: .module, comment: "Export sheet section listing saved report presets")) {
            ForEach(presets) { preset in
                Button { apply(preset) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(preset.name).foregroundStyle(Color.primary)
                        Text(verbatim: "\(preset.definition.range.displayName) · \(chartCountText(preset.definition.sections.count))")
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                }
            }
            .onDelete(perform: deletePresets)
        }
    }

    private func chartCountText(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 chart", bundle: .module, comment: "Number of selected report pages: exactly one")
            : String(localized: "\(count) charts", bundle: .module, comment: "Number of selected report pages; the argument is the count")
    }

    // MARK: - Range

    /// The presets, plus the current range when a loaded preset uses one that is not among them.
    private var rangeOptions: [ReportRange] {
        ranges.contains(range) ? ranges : ranges + [range]
    }

    private var rangeSection: some View {
        Section(String(localized: "Range", bundle: .module, comment: "Export sheet section for the report date range")) {
            Picker(String(localized: "Range", bundle: .module, comment: "Export sheet section for the report date range"), selection: $range) {
                ForEach(rangeOptions, id: \.self) { option in
                    Text(option.shortName).accessibilityLabel(option.displayName).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
    }

    /// Per-day charts are unavailable for a single-day range. They stay in `selected` while
    /// disabled, so switching back to a longer range restores them.
    private func isAvailable(_ section: ReportSection) -> Bool {
        ReportDefinition(range: range, sections: [section]).unsupportedSections(for: range.resolve()).isEmpty
    }

    // MARK: - Include

    private var includeSection: some View {
        Section(String(localized: "Include", bundle: .module, comment: "Export sheet section listing what goes into the report")) {
            ForEach(ReportSection.Category.allCases, id: \.self) { category in
                rows(for: category)
            }
        }
    }

    /// One row per category that expands on tap to list that category's charts directly beneath
    /// it, indented, each with its own toggle. Inclusion is decided purely by the chart toggles;
    /// the row shows how many are selected.
    @ViewBuilder
    private func rows(for category: ReportSection.Category) -> some View {
        categoryRow(category)
        if expanded.contains(category) {
            ForEach(category.sections) { sectionRow($0) }
        }
    }

    private func categoryRow(_ category: ReportSection.Category) -> some View {
        let isExpanded = expanded.contains(category)
        let selectedCount = category.sections.filter { selected.contains($0) && isAvailable($0) }.count

        return Button {
            withAnimation {
                if isExpanded { expanded.remove(category) } else { expanded.insert(category) }
            }
        } label: {
            HStack {
                Text(category.title).foregroundStyle(Color.primary)
                Spacer()
                if selectedCount > 0 {
                    Text(chartCountText(selectedCount)).foregroundStyle(Color.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isExpanded
            ? String(localized: "Expanded", bundle: .module, comment: "Accessibility value of an open category row")
            : String(localized: "Collapsed", bundle: .module, comment: "Accessibility value of a closed category row"))
    }

    private func sectionRow(_ section: ReportSection) -> some View {
        // A disabled Toggle only dims its switch, so grey the title explicitly to match.
        Toggle(isOn: binding(for: section)) {
            Text(section.menuTitle).foregroundStyle(isAvailable(section) ? Color.primary : Color.secondary)
        }
        .disabled(!isAvailable(section))
        .padding(.leading, Self.chartRowInset)
    }

    private func binding(for section: ReportSection) -> Binding<Bool> {
        Binding(
            get: { selected.contains(section) && isAvailable(section) },
            set: { isOn in
                if isOn { selected.insert(section) } else { selected.remove(section) }
            }
        )
    }

    // MARK: - Presets and sharing

    @ViewBuilder
    private var actionsSection: some View {
        Section {
            if presetStore != nil {
                Button(String(localized: "Save as Preset…", bundle: .module, comment: "Button that saves the current range and chart selection")) {
                    // Presets are a reusable chart/range template, not tied to a patient,
                    // so the prompt is not seeded with the patient name.
                    presetName = ""
                    isNamingPreset = true
                }
                .disabled(definition.sections.isEmpty)
            }
            if let exportedFile {
                ShareLink(item: exportedFile.url) {
                    Label(String(localized: "Share \(exportedFile.url.lastPathComponent)", bundle: .module, comment: "Button to share the exported file; the argument is the file name"),
                          systemImage: "square.and.arrow.up")
                }
            }
        } footer: {
            if let errorMessage {
                Text(errorMessage).foregroundStyle(Color.red)
            }
        }
    }

    // MARK: - Actions

    private func export() {
        let definition = self.definition
        let patientName = self.patientName
        isExporting = true
        errorMessage = nil
        removeExportedFile()
        Task { @MainActor in
            defer { isExporting = false }
            do {
                var report = try await makeReport(definition)
                if !patientName.isEmpty {
                    report.metadata.patientName = patientName
                }
                let file = ExportedFile(url: try PDFReportExporter.export(report))
                exportedFile = file
                shareFile = file
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Reports hold health data; don't leave earlier exports behind in the temporary folder.
    private func removeExportedFile() {
        if let url = exportedFile?.url {
            try? FileManager.default.removeItem(at: url)
        }
        exportedFile = nil
    }

    /// A preset is a reusable range/chart template, so loading one leaves the patient name alone.
    private func apply(_ preset: ReportPreset) {
        withAnimation {
            selected = Set(preset.definition.sections)
            expanded = Set(preset.definition.sections.map(\.category))
            range = preset.definition.range
        }
    }

    private func loadPresets() {
        presets = (try? presetStore?.presets()) ?? []
    }

    private func savePreset() {
        let trimmed = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let presetStore, !trimmed.isEmpty else { return }
        do {
            try presetStore.upsert(ReportPreset(name: trimmed, definition: definition))
            loadPresets()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deletePresets(at offsets: IndexSet) {
        guard let presetStore else { return }
        for index in offsets {
            try? presetStore.delete(id: presets[index].id)
        }
        loadPresets()
    }
}

private struct ExportedFile: Identifiable {
    let url: URL
    var id: URL { url }
}

#if canImport(UIKit)
/// Presents the system share sheet as soon as the PDF is written.
private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif

extension JSONFileReportPresetStore {
    /// Presets in the app's Application Support directory.
    public static func applicationSupport(fileName: String = "aidreport-presets.json") -> JSONFileReportPresetStore {
        let directory = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return JSONFileReportPresetStore(url: directory.appendingPathComponent("AIDReportKit").appendingPathComponent(fileName))
    }
}
#endif
