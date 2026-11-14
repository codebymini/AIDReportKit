import Foundation

public enum HostApp: String, Codable, Sendable {
    case loop
    case trio
    case loopFollow
    case nightscout
    case appleHealth
    case merged
    case synthetic
    case other
}

public struct DataSourceInfo: Hashable, Codable, Sendable {
    public var app: HostApp
    /// Human-readable label shown in reports, e.g. "Trio" or "Nightscout + Apple Health".
    public var name: String
    public var appVersion: String?
    /// Unit the user sees in the host app; used by renderers only.
    public var displayUnit: GlucoseUnit
    /// Time zone for daily buckets and time-of-day (AGP) statistics.
    public var timeZoneIdentifier: String

    public init(
        app: HostApp,
        name: String? = nil,
        appVersion: String? = nil,
        displayUnit: GlucoseUnit = .mgdL,
        timeZone: TimeZone = .current
    ) {
        self.app = app
        self.name = name ?? app.defaultName
        self.appVersion = appVersion
        self.displayUnit = displayUnit
        self.timeZoneIdentifier = timeZone.identifier
    }

    public var timeZone: TimeZone { TimeZone(identifier: timeZoneIdentifier) ?? .current }
}

extension HostApp {
    var defaultName: String {
        switch self {
        case .loop: return "Loop"
        case .trio: return "Trio"
        case .loopFollow: return "LoopFollow"
        case .nightscout: return "Nightscout"
        case .appleHealth: return "Apple Health"
        case .merged: return String(localized: "Merged sources", bundle: .module, comment: "Data source name when several sources are combined")
        case .synthetic: return String(localized: "Synthetic data", bundle: .module, comment: "Data source name for generated test data")
        case .other: return String(localized: "Other", bundle: .module, comment: "Data source name for an unknown app")
        }
    }
}

/// Everything a report is built from: one interval of glucose, insulin and carbs.
public struct TherapyDataset: Hashable, Codable, Sendable {
    public var interval: DateInterval
    public var source: DataSourceInfo
    public var glucose: [GlucoseReading]
    public var insulin: [InsulinDose]
    public var carbs: [CarbIntake]

    public init(
        interval: DateInterval,
        source: DataSourceInfo,
        glucose: [GlucoseReading] = [],
        insulin: [InsulinDose] = [],
        carbs: [CarbIntake] = []
    ) {
        self.interval = interval
        self.source = source
        self.glucose = glucose.sorted { $0.date < $1.date }
        self.insulin = insulin.sorted { $0.start < $1.start }
        self.carbs = carbs.sorted { $0.date < $1.date }
    }

    /// Keeps only data inside `interval` (half-open). Basal doses crossing the edges are prorated.
    public func restricted(to interval: DateInterval) -> TherapyDataset {
        TherapyDataset(
            interval: interval,
            source: source,
            glucose: glucose.filter { interval.containsHalfOpen($0.date) },
            insulin: insulin.compactMap { $0.clamped(to: interval) },
            carbs: carbs.filter { interval.containsHalfOpen($0.date) }
        )
    }

    public var isEmpty: Bool { glucose.isEmpty && insulin.isEmpty && carbs.isEmpty }
}
