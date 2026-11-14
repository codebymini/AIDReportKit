import AIDReportKit
import Foundation

public struct ConformanceFailure: Hashable, Sendable, CustomStringConvertible {
    public let check: String
    public let message: String

    public var description: String { "[\(check)] \(message)" }
}

/// Invariants every `TherapyDataSource` should hold. Call from a host app's test target:
///
/// ```swift
/// let failures = try await AdapterConformance.check(TrioTherapyDataSource(context: testContext), interval: lastWeek)
/// XCTAssertEqual(failures, [])
/// ```
///
/// Does not import XCTest, so it can also run as a debug self-check inside the app.
public enum AdapterConformance {
    /// Records further than this outside the requested interval suggest a broken query predicate.
    public static let edgeTolerance: TimeInterval = 24 * 3600

    public static func check(_ source: some TherapyDataSource, interval: DateInterval, now: Date = Date()) async throws -> [ConformanceFailure] {
        check(try await source.dataset(in: interval), now: now)
    }

    public static func check(_ dataset: TherapyDataset, now: Date = Date()) -> [ConformanceFailure] {
        var failures: [ConformanceFailure] = []
        func fail(_ check: String, _ message: String) {
            failures.append(ConformanceFailure(check: check, message: message))
        }

        let outer = DateInterval(
            start: dataset.interval.start.addingTimeInterval(-edgeTolerance),
            end: dataset.interval.end.addingTimeInterval(edgeTolerance)
        )
        let outside = dataset.glucose.filter { !outer.contains($0.date) }.count
            + dataset.carbs.filter { !outer.contains($0.date) }.count
            + dataset.insulin.filter { $0.end < outer.start || $0.start > outer.end }.count
        if outside > 0 {
            fail("query.interval", "\(outside) records are more than a day outside the requested interval")
        }

        for (name, ids) in [
            ("glucose", dataset.glucose.compactMap(\.sourceID)),
            ("bolus", dataset.insulin.filter { $0.kind == .bolus }.compactMap(\.sourceID)),
            ("carbs", dataset.carbs.compactMap(\.sourceID)),
        ] {
            let duplicates = ids.count - Set(ids).count
            if duplicates > 0 {
                fail("ids.unique", "\(duplicates) duplicate \(name) sourceIDs (fetched twice, or an identifier that is not unique)")
            }
        }

        if dataset.insulin.contains(where: { $0.units < 0 || $0.end < $0.start }) {
            fail("insulin.wellFormed", "Doses with negative units or end before start")
        }
        if dataset.insulin.contains(where: { $0.kind == .suspend && $0.units != 0 }) {
            fail("insulin.suspend", "Suspend doses must have 0 units")
        }

        let basal = dataset.insulin.filter(\.isBasalLike).sorted { $0.start < $1.start }
        let overlaps = zip(basal, basal.dropFirst()).filter { $1.start.timeIntervalSince($0.end) < -1 }.count
        if overlaps > 0 {
            fail("insulin.basalOverlap", "\(overlaps) overlapping basal doses; end superseded temp basals (BasalTimeline.truncatingOverlaps)")
        }

        let report = DatasetValidator().validate(dataset, now: now)
        for issue in report.issues(atLeast: .error) {
            fail("validation.\(issue.code)", issue.message)
        }
        return failures
    }
}
