import Foundation

/// Stable, machine-readable issue identifier, e.g. `glucose.likelyMmolL`.
/// Hosts can declare their own codes with a string literal.
public struct ValidationCode: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }
    /// The part before the first dot: `glucose`, `insulin`, `carbs`, `dataset`.
    public var category: String { String(rawValue.prefix { $0 != "." }) }
}

extension ValidationCode {
    public static let glucoseNoData: ValidationCode = "glucose.noData"
    public static let glucoseImplausibleValue: ValidationCode = "glucose.implausibleValue"
    public static let glucoseLikelyMmolL: ValidationCode = "glucose.likelyMmolL"
    public static let glucoseDuplicate: ValidationCode = "glucose.duplicate"
    public static let glucoseRateOfChange: ValidationCode = "glucose.rateOfChange"
    public static let glucoseGap: ValidationCode = "glucose.gap"
    public static let glucoseLowCoverage: ValidationCode = "glucose.lowCoverage"

    public static let insulinNoData: ValidationCode = "insulin.noData"
    public static let insulinNegative: ValidationCode = "insulin.negative"
    public static let insulinEndBeforeStart: ValidationCode = "insulin.endBeforeStart"
    public static let insulinBolusAboveMax: ValidationCode = "insulin.bolusAboveMax"
    public static let insulinBasalRateAboveMax: ValidationCode = "insulin.basalRateAboveMax"
    public static let insulinBasalOverlap: ValidationCode = "insulin.basalOverlap"
    public static let insulinDuplicateBolus: ValidationCode = "insulin.duplicateBolus"
    public static let insulinLowBasalCoverage: ValidationCode = "insulin.lowBasalCoverage"

    public static let carbsNegative: ValidationCode = "carbs.negative"
    public static let carbsAboveMax: ValidationCode = "carbs.aboveMax"
    public static let carbsDuplicate: ValidationCode = "carbs.duplicate"

    public static let datasetFutureTimestamp: ValidationCode = "dataset.futureTimestamp"
    public static let datasetShortSpan: ValidationCode = "dataset.shortSpan"
    public static let validationTruncated: ValidationCode = "validation.truncated"
}

public struct ValidationIssue: Hashable, Codable, Sendable {
    public enum Severity: String, Codable, Sendable, CaseIterable, Comparable {
        /// Worth knowing; statistics are still valid.
        case info
        /// Statistics may be skewed (e.g. low coverage, duplicates that the sanitizer removed).
        case warning
        /// The data is wrong (e.g. mmol/L delivered as mg/dL); statistics should not be trusted.
        case error

        private var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rank < rhs.rank }
    }

    public var code: ValidationCode
    public var severity: Severity
    public var message: String
    public var date: Date?
    public var sourceID: String?

    public init(_ code: ValidationCode, _ severity: Severity, _ message: String, date: Date? = nil, sourceID: String? = nil) {
        self.code = code
        self.severity = severity
        self.message = message
        self.date = date
        self.sourceID = sourceID
    }
}

public struct ValidationReport: Hashable, Codable, Sendable {
    public var issues: [ValidationIssue]

    public init(issues: [ValidationIssue] = []) {
        self.issues = issues
    }

    public var hasErrors: Bool { issues.contains { $0.severity == .error } }

    public func issues(atLeast severity: ValidationIssue.Severity) -> [ValidationIssue] {
        issues.filter { $0.severity >= severity }
    }

    public func count(_ severity: ValidationIssue.Severity) -> Int {
        issues.filter { $0.severity == severity }.count
    }

    public func issues(withCode code: ValidationCode) -> [ValidationIssue] {
        issues.filter { $0.code == code }
    }
}
