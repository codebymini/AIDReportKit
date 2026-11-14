import Foundation

/// Runs validation rules over a raw dataset — before sanitizing — so adapter and data problems
/// are reported rather than silently hidden.
public struct DatasetValidator: Sendable {
    public var rules: [any ValidationRule]
    public var configuration: ValidationConfiguration

    public static let standardRules: [any ValidationRule] = [
        GlucoseValueRule(),
        GlucoseDuplicateRule(),
        GlucoseContinuityRule(),
        InsulinValueRule(),
        InsulinConsistencyRule(),
        CarbRule(),
        DatasetTimingRule(),
    ]

    public init(rules: [any ValidationRule] = DatasetValidator.standardRules, configuration: ValidationConfiguration = ValidationConfiguration()) {
        self.rules = rules
        self.configuration = configuration
    }

    public func validate(_ dataset: TherapyDataset, now: Date = Date()) -> ValidationReport {
        let issues = rules.flatMap { $0.validate(dataset, configuration: configuration, now: now) }
        return ValidationReport(issues: capped(issues))
    }

    /// Keeps the first `maximumIssuesPerCode` issues of each code and summarizes the rest.
    private func capped(_ issues: [ValidationIssue]) -> [ValidationIssue] {
        var counts: [ValidationCode: Int] = [:]
        var kept: [ValidationIssue] = []
        for issue in issues {
            counts[issue.code, default: 0] += 1
            if counts[issue.code]! <= configuration.maximumIssuesPerCode {
                kept.append(issue)
            }
        }
        let summaries = counts
            .filter { $0.value > configuration.maximumIssuesPerCode }
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { code, count in
                ValidationIssue(.validationTruncated, .info,
                                String(localized: "\(count - configuration.maximumIssuesPerCode) more \(code.rawValue) issues not listed",
                                       bundle: .module, comment: "Validation summary; first argument is a count, second a technical issue code"))
            }
        return (kept + summaries).sorted { lhs, rhs in
            lhs.severity != rhs.severity ? lhs.severity > rhs.severity : (lhs.date ?? .distantPast) < (rhs.date ?? .distantPast)
        }
    }
}
