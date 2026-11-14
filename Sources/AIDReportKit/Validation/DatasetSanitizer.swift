import Foundation

/// Produces the dataset statistics are computed from: drops implausible and future records,
/// removes duplicates, ends overlapping temp basals and (optionally) fills basal gaps from a
/// schedule. Does not fix unit errors — those are adapter bugs and are reported as errors.
public struct DatasetSanitizer: Sendable {
    public var configuration: ValidationConfiguration
    public var basalSchedule: BasalSchedule?

    public init(configuration: ValidationConfiguration = ValidationConfiguration(), basalSchedule: BasalSchedule? = nil) {
        self.configuration = configuration
        self.basalSchedule = basalSchedule
    }

    public func sanitize(_ dataset: TherapyDataset, now: Date = Date()) -> TherapyDataset {
        let c = configuration
        let latest = now.addingTimeInterval(c.futureTolerance)

        let glucose = Dedupe.glucose(
            dataset.glucose.filter {
                $0.date <= latest && $0.mgdL >= c.minimumPlausibleGlucose && $0.mgdL <= c.maximumPlausibleGlucose
            },
            window: c.duplicateWindow
        ).kept

        let validDoses = dataset.insulin.filter { $0.units >= 0 && $0.end >= $0.start && $0.start <= latest }
        let boluses = Dedupe.boluses(validDoses.filter { $0.kind == .bolus }, window: c.duplicateWindow).kept
        var insulin = BasalTimeline.truncatingOverlaps(boluses + validDoses.filter(\.isBasalLike))
        let carbs = Dedupe.carbs(
            dataset.carbs.filter { $0.grams >= 0 && $0.date <= latest },
            window: c.duplicateWindow
        ).kept

        // Scheduled basal is only assumed while the app demonstrably had data: between the first
        // and last record of any kind. Before/after that (new install, uploader offline) it stays empty.
        if let schedule = basalSchedule {
            let limit = min(dataset.interval.end, now)
            let recordDates = (glucose.map(\.date) + insulin.flatMap { [$0.start, $0.end] } + carbs.map(\.date))
                .filter { $0 >= dataset.interval.start && $0 <= limit }
            if let first = recordDates.min(), let last = recordDates.max(), last > first {
                insulin = BasalTimeline.fillingGaps(insulin, in: DateInterval(start: first, end: last), with: schedule)
            }
        }

        return TherapyDataset(interval: dataset.interval, source: dataset.source, glucose: glucose, insulin: insulin, carbs: carbs)
            .restricted(to: dataset.interval)
    }
}
