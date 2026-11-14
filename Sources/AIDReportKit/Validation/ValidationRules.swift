import Foundation

/// One check over a dataset. Add custom rules by conforming and passing them to `DatasetValidator`.
public protocol ValidationRule: Sendable {
    func validate(_ dataset: TherapyDataset, configuration: ValidationConfiguration, now: Date) -> [ValidationIssue]
}

// Numbers are formatted before they go into localized messages, so translations only reorder them.
private func minutesText(_ interval: TimeInterval) -> String {
    let minutes = Int((interval / 60).rounded())
    return String(localized: "\(minutes) min", bundle: .module, comment: "Duration in minutes")
}

private func number(_ value: Double, _ decimals: Int) -> String {
    String(format: "%.\(decimals)f", value)
}

private func percent(_ fraction: Double) -> String {
    String(format: "%.0f%%", fraction * 100)
}

// MARK: - Glucose

public struct GlucoseValueRule: ValidationRule {
    public init() {}
    public func validate(_ dataset: TherapyDataset, configuration c: ValidationConfiguration, now: Date) -> [ValidationIssue] {
        var issues = dataset.glucose
            .filter { $0.mgdL < c.minimumPlausibleGlucose || $0.mgdL > c.maximumPlausibleGlucose }
            .map {
                ValidationIssue(.glucoseImplausibleValue, .error,
                                String(localized: "Glucose \(number($0.mgdL, 1)) mg/dL is outside the plausible range", bundle: .module,
                                       comment: "Validation error; the argument is a glucose value"),
                                date: $0.date, sourceID: $0.sourceID)
            }
        let sensor = dataset.glucose.filter { $0.kind == .sensor }.map(\.mgdL).sorted()
        if sensor.count >= 3, Quantile.value(0.5, sorted: sensor) < 30 {
            issues.append(ValidationIssue(.glucoseLikelyMmolL, .error,
                                          String(localized: "Median sensor glucose is below 30; values look like mmol/L delivered as mg/dL", bundle: .module,
                                                 comment: "Validation error: the data source sent mmol/L values where mg/dL were expected")))
        }
        return issues
    }
}

public struct GlucoseDuplicateRule: ValidationRule {
    public init() {}
    public func validate(_ dataset: TherapyDataset, configuration c: ValidationConfiguration, now: Date) -> [ValidationIssue] {
        Dedupe.glucose(dataset.glucose, window: c.duplicateWindow).duplicates.map {
            ValidationIssue(.glucoseDuplicate, .warning,
                            String(localized: "Duplicate glucose reading", bundle: .module, comment: "Validation warning"),
                            date: $0.date, sourceID: $0.sourceID)
        }
    }
}

public struct GlucoseContinuityRule: ValidationRule {
    public init() {}
    public func validate(_ dataset: TherapyDataset, configuration c: ValidationConfiguration, now: Date) -> [ValidationIssue] {
        let sensor = dataset.glucose.filter { $0.kind == .sensor && dataset.interval.containsHalfOpen($0.date) }
        guard let first = sensor.first, let last = sensor.last else {
            return [ValidationIssue(.glucoseNoData, .warning,
                                    String(localized: "No sensor glucose in the interval", bundle: .module, comment: "Validation warning"))]
        }

        var issues: [ValidationIssue] = []
        for (previous, current) in zip(sensor, sensor.dropFirst()) {
            let gap = current.date.timeIntervalSince(previous.date)
            if gap > c.maximumGlucoseGap {
                issues.append(ValidationIssue(.glucoseGap, .info,
                                              String(localized: "Sensor gap of \(minutesText(gap))", bundle: .module,
                                                     comment: "Validation note; the argument is a duration"),
                                              date: previous.date))
            } else if gap >= 60 {
                let rate = abs(current.mgdL - previous.mgdL) / (gap / 60)
                if rate > c.maximumGlucoseRateOfChange {
                    issues.append(ValidationIssue(.glucoseRateOfChange, .warning,
                                                  String(localized: "Glucose changed \(number(rate, 1)) mg/dL/min", bundle: .module,
                                                         comment: "Validation warning about a very fast glucose change"),
                                                  date: current.date, sourceID: current.sourceID))
                }
            }
        }

        let leading = first.date.timeIntervalSince(dataset.interval.start)
        if leading > c.maximumGlucoseGap {
            issues.append(ValidationIssue(.glucoseGap, .info,
                                          String(localized: "No sensor data for the first \(minutesText(leading))", bundle: .module,
                                                 comment: "Validation note; the argument is a duration at the start of the report"),
                                          date: dataset.interval.start))
        }
        let trailing = min(dataset.interval.end, now).timeIntervalSince(last.date)
        if trailing > c.maximumGlucoseGap {
            issues.append(ValidationIssue(.glucoseGap, .info,
                                          String(localized: "No sensor data for the last \(minutesText(trailing))", bundle: .module,
                                                 comment: "Validation note; the argument is a duration at the end of the report"),
                                          date: last.date))
        }

        let effective = DateInterval(start: dataset.interval.start, end: max(dataset.interval.start, min(dataset.interval.end, now)))
        let coverage = GlucoseStatistics.coverage(of: sensor.map(\.date), in: effective)
        if coverage < c.minimumGlucoseCoverage {
            issues.append(ValidationIssue(.glucoseLowCoverage, .warning,
                                          String(localized: "CGM coverage is \(percent(coverage)) (minimum \(percent(c.minimumGlucoseCoverage)))",
                                                 bundle: .module, comment: "Validation warning; arguments are percentages")))
        }
        return issues
    }
}

// MARK: - Insulin

public struct InsulinValueRule: ValidationRule {
    public init() {}
    public func validate(_ dataset: TherapyDataset, configuration c: ValidationConfiguration, now: Date) -> [ValidationIssue] {
        dataset.insulin.compactMap { dose in
            if dose.units < 0 {
                return ValidationIssue(.insulinNegative, .error,
                                       String(localized: "Negative insulin amount \(number(dose.units, 2)) U", bundle: .module,
                                              comment: "Validation error; the argument is insulin units"),
                                       date: dose.start, sourceID: dose.sourceID)
            }
            if dose.end < dose.start {
                return ValidationIssue(.insulinEndBeforeStart, .error,
                                       String(localized: "Dose ends before it starts", bundle: .module, comment: "Validation error"),
                                       date: dose.start, sourceID: dose.sourceID)
            }
            if dose.kind == .bolus, dose.units > c.maximumBolus {
                return ValidationIssue(.insulinBolusAboveMax, .warning,
                                       String(localized: "Bolus of \(number(dose.units, 2)) U exceeds \(number(c.maximumBolus, 0)) U", bundle: .module,
                                              comment: "Validation warning; arguments are insulin units"),
                                       date: dose.start, sourceID: dose.sourceID)
            }
            if dose.isBasalLike, dose.duration >= 60, let rate = dose.ratePerHour, rate > c.maximumBasalRate {
                return ValidationIssue(.insulinBasalRateAboveMax, .warning,
                                       String(localized: "Basal rate \(number(rate, 2)) U/h exceeds \(number(c.maximumBasalRate, 1)) U/h", bundle: .module,
                                              comment: "Validation warning; arguments are insulin units per hour"),
                                       date: dose.start, sourceID: dose.sourceID)
            }
            return nil
        }
    }
}

public struct InsulinConsistencyRule: ValidationRule {
    public init() {}
    public func validate(_ dataset: TherapyDataset, configuration c: ValidationConfiguration, now: Date) -> [ValidationIssue] {
        guard !dataset.insulin.isEmpty else {
            return [ValidationIssue(.insulinNoData, .warning,
                                    String(localized: "No insulin records in the interval", bundle: .module, comment: "Validation warning"))]
        }

        var issues = Dedupe.boluses(dataset.insulin.filter { $0.kind == .bolus }, window: c.duplicateWindow).duplicates.map {
            ValidationIssue(.insulinDuplicateBolus, .warning,
                            String(localized: "Duplicate bolus of \(number($0.units, 2)) U", bundle: .module,
                                   comment: "Validation warning; the argument is insulin units"),
                            date: $0.start, sourceID: $0.sourceID)
        }

        let basal = dataset.insulin.filter(\.isBasalLike).sorted { $0.start < $1.start }
        for (current, next) in zip(basal, basal.dropFirst()) where next.start.timeIntervalSince(current.end) < -1 {
            issues.append(ValidationIssue(.insulinBasalOverlap, .warning,
                                          String(localized: "Basal records overlap by \(minutesText(current.end.timeIntervalSince(next.start)))",
                                                 bundle: .module, comment: "Validation warning; the argument is a duration"),
                                          date: next.start, sourceID: next.sourceID))
        }

        let effective = DateInterval(start: dataset.interval.start, end: max(dataset.interval.start, min(dataset.interval.end, now)))
        let coverage = BasalTimeline.coverage(dataset.insulin, in: effective)
        if coverage < c.minimumBasalCoverage {
            issues.append(ValidationIssue(.insulinLowBasalCoverage, .warning,
                                          String(localized: "Basal records cover \(percent(coverage)) of the interval; basal totals undercount unless a basal schedule is provided",
                                                 bundle: .module, comment: "Validation warning; the argument is a percentage")))
        }
        return issues
    }
}

// MARK: - Carbs

public struct CarbRule: ValidationRule {
    public init() {}
    public func validate(_ dataset: TherapyDataset, configuration c: ValidationConfiguration, now: Date) -> [ValidationIssue] {
        var issues: [ValidationIssue] = dataset.carbs.compactMap { entry in
            if entry.grams < 0 {
                return ValidationIssue(.carbsNegative, .error,
                                       String(localized: "Negative carb entry \(number(entry.grams, 0)) g", bundle: .module,
                                              comment: "Validation error; the argument is grams of carbohydrate"),
                                       date: entry.date, sourceID: entry.sourceID)
            }
            if entry.grams > c.maximumCarbEntry {
                return ValidationIssue(.carbsAboveMax, .warning,
                                       String(localized: "Carb entry of \(number(entry.grams, 0)) g exceeds \(number(c.maximumCarbEntry, 0)) g", bundle: .module,
                                              comment: "Validation warning; arguments are grams of carbohydrate"),
                                       date: entry.date, sourceID: entry.sourceID)
            }
            return nil
        }
        issues += Dedupe.carbs(dataset.carbs, window: c.duplicateWindow).duplicates.map {
            ValidationIssue(.carbsDuplicate, .warning,
                            String(localized: "Duplicate carb entry of \(number($0.grams, 0)) g", bundle: .module,
                                   comment: "Validation warning; the argument is grams of carbohydrate"),
                            date: $0.date, sourceID: $0.sourceID)
        }
        return issues
    }
}

// MARK: - Dataset

public struct DatasetTimingRule: ValidationRule {
    public init() {}
    public func validate(_ dataset: TherapyDataset, configuration c: ValidationConfiguration, now: Date) -> [ValidationIssue] {
        let latest = now.addingTimeInterval(c.futureTolerance)
        let future: [(Date, String?)] =
            dataset.glucose.filter { $0.date > latest }.map { ($0.date, $0.sourceID) }
            + dataset.insulin.filter { $0.start > latest }.map { ($0.start, $0.sourceID) }
            + dataset.carbs.filter { $0.date > latest }.map { ($0.date, $0.sourceID) }
        var issues = future.map {
            ValidationIssue(.datasetFutureTimestamp, .error,
                            String(localized: "Record is dated in the future (clock or time-zone problem)", bundle: .module, comment: "Validation error"),
                            date: $0.0, sourceID: $0.1)
        }
        if dataset.interval.duration < c.recommendedSpan {
            issues.append(ValidationIssue(.datasetShortSpan, .info,
                                          String(localized: "Report covers \(number(dataset.interval.duration / 86400, 1)) days; GMI and time-in-range targets assume at least \(number(c.recommendedSpan / 86400, 0)) days",
                                                 bundle: .module, comment: "Validation note; arguments are numbers of days")))
        }
        return issues
    }
}
