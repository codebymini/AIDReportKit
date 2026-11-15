import Foundation

/// The period a report covers.
public enum ReportRange: Hashable, Codable, Sendable {
    /// Rolling window ending when the report is generated (same fixed offsets as Trio's stats ranges).
    /// Its first and last calendar days are partial; reports say so (see `DataSpan`).
    case lastDays(Int)
    case custom(DateInterval)

    public static let day = ReportRange.lastDays(1)
    public static let week = ReportRange.lastDays(7)
    public static let twoWeeks = ReportRange.lastDays(14)
    public static let month = ReportRange.lastDays(30)
    public static let threeMonths = ReportRange.lastDays(90)
    /// The ranges offered in the export sheet: the same D / W / M / 3 M as Trio's statistics.
    /// Other ranges (`.twoWeeks`, `.lastDays(n)`, `.custom`) remain valid in definitions and presets.
    public static let presets: [ReportRange] = [.day, .week, .month, .threeMonths]

    /// The presets a host that keeps only `history` of data can honour (Loop's stores hold 7
    /// days). A longer range would average that data over days the host knows nothing about.
    public static func presets(within history: TimeInterval) -> [ReportRange] {
        presets.filter { $0.resolve().duration <= history }
    }

    public func resolve(now: Date = Date()) -> DateInterval {
        switch self {
        case let .lastDays(days):
            return DateInterval(start: now.addingTimeInterval(-Double(max(days, 1)) * 86400), end: now)
        case let .custom(interval):
            return interval
        }
    }

    public var displayName: String {
        switch self {
        case .lastDays(1):
            return String(localized: "Last 24 hours", bundle: .module, comment: "Report range: the 24 hours before the report was made")
        case let .lastDays(days):
            return String(localized: "Last \(days) days", bundle: .module, comment: "Report range: rolling number of days ending when the report is made")
        case .custom:
            return String(localized: "Custom range", bundle: .module, comment: "Report range picked by the user")
        }
    }

    /// Compact name for a segmented range picker ("D", "W", "M", "3 M").
    public var shortName: String {
        switch self {
        case .lastDays(1):
            return String(localized: "D", bundle: .module, comment: "Short range name: one day")
        case .lastDays(7):
            return String(localized: "W", bundle: .module, comment: "Short range name: one week")
        case .lastDays(14):
            return String(localized: "2 W", bundle: .module, comment: "Short range name: two weeks")
        case .lastDays(30):
            return String(localized: "M", bundle: .module, comment: "Short range name: one month")
        case .lastDays(90):
            return String(localized: "3 M", bundle: .module, comment: "Short range name: three months")
        case let .lastDays(days):
            return String(localized: "\(days) D", bundle: .module, comment: "Short range name: a number of days")
        case .custom:
            return String(localized: "Custom", bundle: .module, comment: "Short range name: range picked by the user")
        }
    }
}

/// Everything a report can contain, across all categories, as one flat list.
/// A report is an ordered list of these; renderers produce one page/section per entry.
///
/// Case order is the PDF page order: the overview, then the charts in the order the export menu
/// lists them (glucose, carbs, insulin — the same order as Trio's statistics export), then data
/// quality as the closing page.
public enum ReportSection: String, Codable, CaseIterable, Sendable, Identifiable {
    case overview
    case glucoseDistribution
    case glycemiaRiskIndex
    case glucosePercentileByDay
    case glucoseDistributionByDay
    case glucoseHeatmapByDay
    case carbsTotals
    case insulinTotalDailyDose
    case insulinBolusDistribution
    case dataQuality

    /// The rows of the export menu, in the order they are listed.
    public enum Category: String, Codable, Sendable, CaseIterable {
        /// Overview and data quality: the pages that are not a single chart.
        case summary
        case glucose, carbs, insulin

        /// Localized title (from the package's String Catalog).
        public var title: String {
            switch self {
            case .summary: return String(localized: "Summary", bundle: .module, comment: "Report category heading: overview and data quality pages")
            case .glucose: return String(localized: "Glucose", bundle: .module, comment: "Report category heading")
            case .carbs: return String(localized: "Carbs", bundle: .module, comment: "Carbohydrates, short: report category heading and table column header")
            case .insulin: return String(localized: "Insulin", bundle: .module, comment: "Report category heading")
            }
        }

        /// This category's sections, in menu order.
        public var sections: [ReportSection] {
            ReportSection.allCases.filter { $0.category == self }
        }
    }

    public var id: String { rawValue }

    public var category: Category {
        switch self {
        case .overview, .dataQuality: return .summary
        case .glucoseDistribution, .glucoseDistributionByDay, .glucosePercentileByDay,
             .glucoseHeatmapByDay, .glycemiaRiskIndex:
            return .glucose
        case .insulinTotalDailyDose, .insulinBolusDistribution: return .insulin
        case .carbsTotals: return .carbs
        }
    }

    /// Short localized name for the export menu, where the category row above already says
    /// "Glucose", "Carbs" or "Insulin". Matches the chart names in Trio's statistics.
    public var menuTitle: String {
        switch self {
        case .overview:
            return String(localized: "Overview", bundle: .module, comment: "Report category and section heading")
        case .glucoseDistribution:
            return String(localized: "Distribution", bundle: .module, comment: "Export menu chart name: time in ranges")
        case .glycemiaRiskIndex:
            return String(localized: "Glycemia Risk Index", bundle: .module, comment: "Report section: GRI score")
        case .glucosePercentileByDay:
            return String(localized: "Percentile (by day)", bundle: .module, comment: "Export menu chart name: glucose percentiles for each day")
        case .glucoseDistributionByDay:
            return String(localized: "Distribution (by day)", bundle: .module, comment: "Export menu chart name: time in ranges for each day")
        case .glucoseHeatmapByDay:
            return String(localized: "Heatmap (by day)", bundle: .module, comment: "Export menu chart name: calendar shaded by each day's average glucose")
        case .carbsTotals:
            return String(localized: "Total Meals", bundle: .module, comment: "Export menu chart name: carbs, fat and protein per day")
        case .insulinTotalDailyDose:
            return String(localized: "Total Daily Dose", bundle: .module, comment: "Report section: insulin per day")
        case .insulinBolusDistribution:
            return String(localized: "Bolus Distribution", bundle: .module, comment: "Report section: manual vs automatic vs external boluses")
        case .dataQuality:
            return String(localized: "Data Quality", bundle: .module, comment: "Report section: coverage and validation issues")
        }
    }

    /// Localized title (from the package's String Catalog).
    public var title: String {
        switch self {
        case .overview:
            return String(localized: "Overview", bundle: .module, comment: "Report category and section heading")
        case .glucoseDistribution:
            return String(localized: "Glucose Distribution", bundle: .module, comment: "Report section: time in ranges and glucose metrics")
        case .glucoseDistributionByDay:
            return String(localized: "Glucose Distribution by Day", bundle: .module, comment: "Report section: time in ranges for each day")
        case .glucosePercentileByDay:
            return String(localized: "Glucose Percentiles by Day", bundle: .module, comment: "Report section: glucose percentiles for each day")
        case .glucoseHeatmapByDay:
            return String(localized: "Average Glucose by Day", bundle: .module, comment: "Report section: calendar shaded by each day's average glucose")
        case .glycemiaRiskIndex:
            return String(localized: "Glycemia Risk Index", bundle: .module, comment: "Report section: GRI score")
        case .insulinTotalDailyDose:
            return String(localized: "Total Daily Dose", bundle: .module, comment: "Report section: insulin per day")
        case .insulinBolusDistribution:
            return String(localized: "Bolus Distribution", bundle: .module, comment: "Report section: manual vs automatic vs external boluses")
        case .carbsTotals:
            return String(localized: "Carbohydrates", bundle: .module, comment: "Report category and section heading")
        case .dataQuality:
            return String(localized: "Data Quality", bundle: .module, comment: "Report section: coverage and validation issues")
        }
    }

    /// By-day sections need at least two days to show anything useful.
    public var minimumDays: Int {
        switch self {
        case .glucoseDistributionByDay, .glucosePercentileByDay, .glucoseHeatmapByDay: return 2
        default: return 1
        }
    }

    /// One entry per day: has nothing meaningful to show for a single-day range.
    public var isPerDay: Bool { minimumDays > 1 }

    /// Shows a value for each calendar day, so a partial first or last day looks smaller than it
    /// was. These sections carry the partial-day warning.
    public var showsDailyValues: Bool {
        switch self {
        case .glucosePercentileByDay, .glucoseDistributionByDay, .glucoseHeatmapByDay,
             .carbsTotals, .insulinTotalDailyDose, .insulinBolusDistribution:
            return true
        case .overview, .glucoseDistribution, .glycemiaRiskIndex, .dataQuality:
            return false
        }
    }
}

/// What to put in a report: name, range and ordered sections.
public struct ReportDefinition: Hashable, Codable, Sendable {
    /// Names a saved preset in the export sheet. Not printed in the report.
    public var name: String
    public var range: ReportRange
    public var sections: [ReportSection]

    public static let defaultSections: [ReportSection] = [
        .overview, .glucoseDistribution, .glycemiaRiskIndex,
        .carbsTotals, .insulinTotalDailyDose, .dataQuality,
    ]

    public static let standard = ReportDefinition()

    public init(name: String = "", range: ReportRange = .month, sections: [ReportSection] = ReportDefinition.defaultSections) {
        self.name = name
        self.range = range
        self.sections = sections
    }

    private enum CodingKeys: String, CodingKey {
        case name, range, sections
    }

    /// Skips sections this version does not know, so saved presets keep loading after a section
    /// is removed (the AGP page, `glucosePercentileByTime`) or one from a newer version appears.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        range = try container.decode(ReportRange.self, forKey: .range)
        sections = try container.decode([String].self, forKey: .sections).compactMap(ReportSection.init(rawValue:))
    }

    /// Sections that cannot be produced for `interval` (e.g. by-day charts on a 1-day report).
    public func unsupportedSections(for interval: DateInterval) -> [ReportSection] {
        let days = interval.duration / 86400
        return sections.filter { Double($0.minimumDays) > days + 0.001 }
    }
}

/// Header information so a printed report can be read on its own.
public struct ReportMetadata: Hashable, Codable, Sendable {
    public struct Item: Hashable, Codable, Sendable {
        public var label: String
        public var value: String
        public init(_ label: String, _ value: String) {
            self.label = label
            self.value = value
        }
    }

    /// Printed under the report title. `ReportExportView` asks for it on every export.
    public var patientName: String?
    public var appName: String?
    public var appVersion: String?
    public var buildDate: String?
    public var cgm: String?
    public var pump: String?
    public var device: String?
    /// Host-chosen settings that help interpret the numbers (closed loop, SMB, dynamic ISF, …).
    public var settings: [Item]

    public init(
        patientName: String? = nil,
        appName: String? = nil,
        appVersion: String? = nil,
        buildDate: String? = nil,
        cgm: String? = nil,
        pump: String? = nil,
        device: String? = nil,
        settings: [Item] = []
    ) {
        self.patientName = patientName
        self.appName = appName
        self.appVersion = appVersion
        self.buildDate = buildDate
        self.cgm = cgm
        self.pump = pump
        self.device = device
        self.settings = settings
    }

    public var hardwareItems: [Item] {
        Self.items([
            (String(localized: "CGM", bundle: .module, comment: "Report header label for the continuous glucose monitor"), cgm),
            (String(localized: "Pump", bundle: .module, comment: "Report header label for the insulin pump"), pump),
            (String(localized: "Device", bundle: .module, comment: "Report header label for the phone model"), device),
        ])
    }

    public var softwareItems: [Item] {
        Self.items([
            (String(localized: "App", bundle: .module, comment: "Report header label for the app name"), appName),
            (String(localized: "Version", bundle: .module, comment: "Report header label for the app version"), appVersion),
            (String(localized: "Build date", bundle: .module, comment: "Report header label for when the app was built"), buildDate),
        ])
    }

    /// Drops missing and empty values (e.g. no pump paired yet).
    private static func items(_ pairs: [(String, String?)]) -> [Item] {
        pairs.compactMap { label, value in
            guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return Item(label, value)
        }
    }

    /// The patient name without surrounding whitespace, or `nil` when there is none to print.
    public var printablePatientName: String? {
        guard let name = patientName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return name
    }

    /// Whether there is no hardware, software or settings information to print.
    public var isEmpty: Bool { hardwareItems.isEmpty && softwareItems.isEmpty && settings.isEmpty }
}
