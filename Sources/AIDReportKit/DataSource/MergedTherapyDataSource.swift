import Foundation

/// How a `MergedTherapyDataSource` combines one stream (glucose, insulin or carbs) across sources.
public enum MergeStrategy: Hashable, Sendable {
    /// Use only the first source.
    case primaryOnly
    /// Use the first source (in order) that returns any data for the interval.
    case firstNonEmpty
    /// Start from the first source; add records from later sources only where nothing from an
    /// earlier source lies within `window`. Basal-like doses are clipped to uncovered time.
    case fillGaps(window: TimeInterval)
}

/// Combines several sources — typically a host app's own store, Nightscout and Apple Health —
/// into one, without double counting the data each app mirrors to the others.
///
/// Defaults: glucose fills gaps (a reading missing from Nightscout can come from Health),
/// insulin and carbs come whole from the first source that has any, because partial
/// insulin merges are where double counting happens.
///
/// A source that throws is skipped; the merge throws only if every source fails.
public final class MergedTherapyDataSource: TherapyDataSource {
    public let sources: [any TherapyDataSource]
    public let info: DataSourceInfo
    public var glucoseStrategy: MergeStrategy
    public var insulinStrategy: MergeStrategy
    public var carbStrategy: MergeStrategy

    public init(
        _ sources: [any TherapyDataSource],
        info: DataSourceInfo? = nil,
        glucose: MergeStrategy = .fillGaps(window: 150),
        insulin: MergeStrategy = .firstNonEmpty,
        carbs: MergeStrategy = .firstNonEmpty
    ) {
        precondition(!sources.isEmpty, "MergedTherapyDataSource needs at least one source")
        self.sources = sources
        let primary = sources[0].info
        self.info = info ?? DataSourceInfo(
            app: .merged,
            name: sources.map(\.info.name).joined(separator: " + "),
            appVersion: primary.appVersion,
            displayUnit: primary.displayUnit,
            timeZone: primary.timeZone
        )
        self.glucoseStrategy = glucose
        self.insulinStrategy = insulin
        self.carbStrategy = carbs
    }

    public func glucose(in interval: DateInterval) async throws -> [GlucoseReading] {
        Self.combine(try await fetchAll(glucoseStrategy) { try await $0.glucose(in: interval) }, glucoseStrategy, fill: Self.fillGlucose)
    }

    public func insulin(in interval: DateInterval) async throws -> [InsulinDose] {
        Self.combine(try await fetchAll(insulinStrategy) { try await $0.insulin(in: interval) }, insulinStrategy, fill: Self.fillInsulin)
    }

    public func carbs(in interval: DateInterval) async throws -> [CarbIntake] {
        Self.combine(try await fetchAll(carbStrategy) { try await $0.carbs(in: interval) }, carbStrategy, fill: Self.fillCarbs)
    }

    /// One `dataset(in:)` call per source, so sources that fetch several streams in one round trip
    /// (Nightscout treatments) are not asked twice.
    public func dataset(in interval: DateInterval) async throws -> TherapyDataset {
        let strategies = [glucoseStrategy, insulinStrategy, carbStrategy]
        let needed = strategies.allSatisfy { $0 == .primaryOnly } ? Array(sources.prefix(1)) : sources
        var datasets: [TherapyDataset?] = []
        var firstError: Error?
        for source in needed {
            do {
                datasets.append(try await source.dataset(in: interval))
            } catch {
                firstError = firstError ?? error
                datasets.append(nil)
            }
        }
        if datasets.allSatisfy({ $0 == nil }), let firstError { throw firstError }
        return TherapyDataset(
            interval: interval,
            source: info,
            glucose: Self.combine(datasets.map { $0?.glucose ?? [] }, glucoseStrategy, fill: Self.fillGlucose),
            insulin: Self.combine(datasets.map { $0?.insulin ?? [] }, insulinStrategy, fill: Self.fillInsulin),
            carbs: Self.combine(datasets.map { $0?.carbs ?? [] }, carbStrategy, fill: Self.fillCarbs)
        )
    }

    // MARK: - Merging

    private static func fillGlucose(_ base: [GlucoseReading], _ candidates: [GlucoseReading], _ window: TimeInterval) -> [GlucoseReading] {
        fillPoints(base: base, candidates: candidates, window: window, date: \.date)
    }

    private static func fillCarbs(_ base: [CarbIntake], _ candidates: [CarbIntake], _ window: TimeInterval) -> [CarbIntake] {
        fillPoints(base: base, candidates: candidates, window: window, date: \.date)
    }

    private static func fillInsulin(_ base: [InsulinDose], _ candidates: [InsulinDose], _ window: TimeInterval) -> [InsulinDose] {
        do {
            let boluses = Self.fillPoints(
                base: base.filter { !$0.isBasalLike },
                candidates: candidates.filter { !$0.isBasalLike },
                window: window,
                date: \.start
            )
            let basal = base.filter(\.isBasalLike)
            let covered = BasalTimeline.coveredIntervals(basal)
            let extraBasal = candidates.filter(\.isBasalLike).flatMap { dose -> [InsulinDose] in
                guard dose.duration > 0 else { return [] }
                return BasalTimeline.gaps(in: DateInterval(start: dose.start, end: dose.end), covered: covered)
                    .compactMap { dose.clamped(to: $0) }
            }
            return boluses + basal + extraBasal
        }
    }

    /// Fetches one stream from every source (only the first for `.primaryOnly`). A source that
    /// throws contributes nothing; the call throws only if every source fails.
    private func fetchAll<T>(_ strategy: MergeStrategy, _ fetch: (any TherapyDataSource) async throws -> [T]) async throws -> [[T]] {
        if case .primaryOnly = strategy {
            return [try await fetch(sources[0])]
        }
        var results: [[T]] = []
        var errors: [Error] = []
        for source in sources {
            do {
                results.append(try await fetch(source))
            } catch {
                errors.append(error)
                results.append([])
            }
        }
        if errors.count == sources.count, let first = errors.first {
            throw first
        }
        return results
    }

    static func combine<T>(_ results: [[T]], _ strategy: MergeStrategy, fill: ([T], [T], TimeInterval) -> [T]) -> [T] {
        guard let first = results.first else { return [] }
        switch strategy {
        case .primaryOnly:
            return first
        case .firstNonEmpty:
            return results.first { !$0.isEmpty } ?? []
        case let .fillGaps(window):
            return results.dropFirst().reduce(first) { merged, next in fill(merged, next, window) }
        }
    }

    /// Adds each candidate whose timestamp is more than `window` from every record in `base`.
    static func fillPoints<T>(base: [T], candidates: [T], window: TimeInterval, date: (T) -> Date) -> [T] {
        let baseDates = base.map(date).sorted()
        let additions = candidates.filter { candidate in
            nearestDistance(to: date(candidate), in: baseDates) > window
        }
        return base + additions
    }

    private static func nearestDistance(to target: Date, in sorted: [Date]) -> TimeInterval {
        guard !sorted.isEmpty else { return .infinity }
        var low = 0
        var high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] < target { low = mid + 1 } else { high = mid }
        }
        var best = TimeInterval.infinity
        if low < sorted.count { best = min(best, abs(sorted[low].timeIntervalSince(target))) }
        if low > 0 { best = min(best, abs(sorted[low - 1].timeIntervalSince(target))) }
        return best
    }
}
