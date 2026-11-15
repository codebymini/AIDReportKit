import Foundation

/// A fully computed report: what renderers (Markdown, JSON, CSV, PDF) consume.
public struct TherapyReport: Hashable, Codable, Sendable {
    /// 2: `dayPeriods` and `settings` added.
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var definition: ReportDefinition
    public var interval: DateInterval
    public var generatedAt: Date
    public var source: DataSourceInfo
    public var metadata: ReportMetadata
    public var thresholds: GlucoseThresholds
    public var summary: TherapySummary
    public var daily: [DailySummary]
    public var agp: AGPProfile
    /// Time in ranges for night, morning, afternoon and evening, all days overlaid.
    public var dayPeriods: [DayPeriodRanges]
    /// Issues found in the raw data, before sanitizing.
    public var validation: ValidationReport
    /// The first and last data point the statistics rest on; `nil` when there is no data.
    public var dataSpan: DataSpan?
    /// Basal rates, carb ratios, ISF, targets and other settings in force when the report was
    /// made; `nil` when the app supplied none.
    public var settings: TherapySettingsSnapshot?

    public var displayUnit: GlucoseUnit { source.displayUnit }

    /// The same for every report, whichever app made it and whatever preset it came from: the app
    /// is named under Software in the header, and a preset's name is only for finding it again.
    public var title: String {
        String(localized: "Glucose Report", bundle: .module, comment: "Report title, at the top of every PDF page and of text exports")
    }

    /// The definition's sections in order, minus those that do not fit the interval.
    public var renderableSections: [ReportSection] {
        let unsupported = Set(definition.unsupportedSections(for: interval))
        return definition.sections.filter { !unsupported.contains($0) }
    }
}

public struct ReportOptions: Sendable {
    public var thresholds: GlucoseThresholds
    public var validation: ValidationConfiguration
    /// Extra host-specific rules run after the standard ones.
    public var additionalRules: [any ValidationRule]
    /// Fills basal gaps (needed for Trio and Nightscout, which only record temp basals) and is
    /// the programmed basal reports compare delivered basal with.
    public var basalSchedule: BasalSchedule?
    /// Carb ratios, ISF, targets and other settings printed on the Insulin and Settings pages.
    /// The basal schedule above is shown with them.
    public var therapySettings: TherapySettingsSnapshot?
    public var agpBucketMinutes: Int
    public var metadata: ReportMetadata

    public init(
        thresholds: GlucoseThresholds = .consensus,
        validation: ValidationConfiguration = ValidationConfiguration(),
        additionalRules: [any ValidationRule] = [],
        basalSchedule: BasalSchedule? = nil,
        therapySettings: TherapySettingsSnapshot? = nil,
        agpBucketMinutes: Int = 60,
        metadata: ReportMetadata = ReportMetadata()
    ) {
        self.thresholds = thresholds
        self.validation = validation
        self.additionalRules = additionalRules
        self.basalSchedule = basalSchedule
        self.therapySettings = therapySettings
        self.agpBucketMinutes = agpBucketMinutes
        self.metadata = metadata
    }

    /// The settings a report prints: `therapySettings` with the basal schedule filled in.
    var reportedSettings: TherapySettingsSnapshot? {
        var settings = therapySettings ?? TherapySettingsSnapshot()
        if settings.basalSchedule == nil {
            settings.basalSchedule = basalSchedule
        }
        return settings.isEmpty ? nil : settings
    }
}

/// Validate (raw) → sanitize → aggregate.
public struct ReportBuilder: Sendable {
    public var options: ReportOptions

    public init(options: ReportOptions = ReportOptions()) {
        self.options = options
    }

    public func build(_ definition: ReportDefinition, from raw: TherapyDataset, now: Date = Date()) -> TherapyReport {
        let validator = DatasetValidator(
            rules: DatasetValidator.standardRules + options.additionalRules,
            configuration: options.validation
        )
        var validation = validator.validate(raw, now: now)
        if options.basalSchedule != nil {
            // Gaps are filled from the schedule, so low raw coverage no longer skews totals.
            validation.issues.removeAll { $0.code == .insulinLowBasalCoverage }
        }

        var clean = DatasetSanitizer(configuration: options.validation, basalSchedule: options.basalSchedule)
            .sanitize(raw, now: now)
        // Time that has not happened yet is not missing data: statistics run up to `now`.
        if raw.interval.end > now, now > raw.interval.start {
            clean = clean.restricted(to: DateInterval(start: raw.interval.start, end: now))
        }
        let aggregator = StatsAggregator(
            thresholds: options.thresholds,
            timeZone: raw.source.timeZone,
            agpBucketMinutes: options.agpBucketMinutes,
            basalSchedule: options.basalSchedule
        )

        return TherapyReport(
            schemaVersion: TherapyReport.currentSchemaVersion,
            definition: definition,
            interval: raw.interval,
            generatedAt: now,
            source: raw.source,
            metadata: options.metadata,
            thresholds: options.thresholds,
            summary: aggregator.summary(clean),
            daily: aggregator.daily(clean),
            agp: aggregator.agp(clean),
            dayPeriods: aggregator.dayPeriods(clean),
            validation: validation,
            dataSpan: clean.dataSpan,
            settings: options.reportedSettings
        )
    }
}

/// Entry point for hosts.
public enum AIDReport {
    /// Fetches `definition.range` from `source` and builds the report.
    public static func generate(
        _ definition: ReportDefinition = .standard,
        from source: some TherapyDataSource,
        options: ReportOptions = ReportOptions(),
        now: Date = Date()
    ) async throws -> TherapyReport {
        let raw = try await source.dataset(in: definition.range.resolve(now: now))
        return ReportBuilder(options: options).build(definition, from: raw, now: now)
    }
}
