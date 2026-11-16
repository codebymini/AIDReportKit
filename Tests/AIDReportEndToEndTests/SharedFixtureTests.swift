import AIDReportKit
import AIDReportTesting
import Foundation
import XCTest

/// The report fixtures in `Fixtures/reports` that the Swift and Kotlin code must both reproduce.
///
/// Each case is a folder with `input.json` (the dataset, the report options and the time the report
/// is made) and `report.json` (the report this package builds from it). This test rebuilds every
/// case from its input and compares the result with `report.json`; the Kotlin tests do the same.
///
/// To change the cases or record a deliberate change in the numbers, regenerate both files:
///
///     AIDREPORT_UPDATE_FIXTURES=1 xcrun swift test --filter SharedFixtureTests
final class SharedFixtureTests: XCTestCase {
    func testEveryCaseMatchesItsReport() throws {
        if ProcessInfo.processInfo.environment["AIDREPORT_UPDATE_FIXTURES"] == "1" {
            try SharedFixtures.write()
        }
        let cases = try SharedFixtures.caseDirectories()
        XCTAssertFalse(cases.isEmpty, "No cases in \(SharedFixtures.directory.path)")
        for directory in cases {
            let input = try SharedFixtures.decoder.decode(SharedFixtureInput.self, from: Data(contentsOf: directory.appendingPathComponent("input.json")))
            let report = ReportBuilder(options: input.options).build(input.definition, from: input.dataset, now: input.now)
            let actual = try JSONSerialization.jsonObject(with: JSONReportRenderer().render(report))
            let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("report.json")))
            let differences = SharedFixtures.differences(expected, actual)
            XCTAssertTrue(differences.isEmpty, "\(directory.lastPathComponent):\n" + differences.prefix(20).joined(separator: "\n"))
        }
    }

    /// The reports the Kotlin tests write (`Kotlin/aidreport-core/build/fixture-output`) decode here
    /// and say the same as Swift's: a report made on Android reads on iOS. Skipped until the Kotlin
    /// tests have run.
    func testKotlinReportsDecodeToTheSameReport() throws {
        let output = SharedFixtures.directory.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Kotlin/aidreport-core/build/fixture-output")
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw XCTSkip("Run the Kotlin tests first: cd Kotlin && ./gradlew :aidreport-core:jvmTest")
        }
        for directory in try SharedFixtures.caseDirectories() {
            let kotlinFile = output.appendingPathComponent("\(directory.lastPathComponent).json")
            let report = try JSONReportRenderer().decode(Data(contentsOf: kotlinFile))
            let actual = try JSONSerialization.jsonObject(with: JSONReportRenderer().render(report))
            let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("report.json")))
            let differences = SharedFixtures.differences(expected, actual)
            XCTAssertTrue(differences.isEmpty, "\(directory.lastPathComponent):\n" + differences.prefix(20).joined(separator: "\n"))
        }
    }
}

/// What a case feeds the report builder. Every field but `now`, `definition` and `dataset` is
/// optional and falls back to `ReportOptions`' default.
struct SharedFixtureInput: Codable {
    var now: Date
    var definition: ReportDefinition
    var dataset: TherapyDataset
    var thresholds: GlucoseThresholds?
    var validation: ValidationConfiguration?
    var basalSchedule: BasalSchedule?
    var therapySettings: TherapySettingsSnapshot?
    var agpBucketMinutes: Int?
    var metadata: ReportMetadata?

    var options: ReportOptions {
        ReportOptions(
            thresholds: thresholds ?? .consensus,
            validation: validation ?? ValidationConfiguration(),
            basalSchedule: basalSchedule,
            therapySettings: therapySettings,
            agpBucketMinutes: agpBucketMinutes ?? 60,
            metadata: metadata ?? ReportMetadata()
        )
    }
}

enum SharedFixtures {
    private typealias S = GoldenScenario

    /// `Fixtures/reports` at the root of the repository.
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/reports")

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func caseDirectories() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("input.json").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - Comparing

    /// Where `actual` differs from `expected`, as JSON paths. Numbers may differ by a relative
    /// 1e-9 (the two languages add in different orders); validation messages are not compared,
    /// because they are translated.
    static func differences(_ expected: Any, _ actual: Any, path: String = "$") -> [String] {
        switch (expected, actual) {
        case let (e as [String: Any], a as [String: Any]):
            let keys = Set(e.keys).union(a.keys).subtracting(["message"]).sorted()
            return keys.flatMap { key -> [String] in
                switch (e[key], a[key]) {
                case let (ev?, av?): return differences(ev, av, path: "\(path).\(key)")
                case (nil, _): return ["\(path).\(key): not expected"]
                case (_, nil): return ["\(path).\(key): missing"]
                }
            }
        case let (e as [Any], a as [Any]):
            guard e.count == a.count else { return ["\(path): \(a.count) items, expected \(e.count)"] }
            return zip(e, a).enumerated().flatMap { index, pair in differences(pair.0, pair.1, path: "\(path)[\(index)]") }
        case let (e as NSNumber, a as NSNumber):
            if isBool(e) || isBool(a) {
                return e == a && isBool(e) == isBool(a) ? [] : ["\(path): \(a), expected \(e)"]
            }
            let x = e.doubleValue, y = a.doubleValue
            return abs(x - y) <= 1e-9 * max(1, abs(x), abs(y)) ? [] : ["\(path): \(y), expected \(x)"]
        case let (e as String, a as String):
            return e == a ? [] : ["\(path): \"\(a)\", expected \"\(e)\""]
        case (is NSNull, is NSNull):
            return []
        default:
            return ["\(path): \(actual), expected \(expected)"]
        }
    }

    private static func isBool(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    // MARK: - Writing

    static func write() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for (name, input) in cases {
            let folder = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try encoder.encode(input).write(to: folder.appendingPathComponent("input.json"), options: .atomic)
            let report = ReportBuilder(options: input.options).build(input.definition, from: input.dataset, now: input.now)
            try JSONReportRenderer().render(report).write(to: folder.appendingPathComponent("report.json"), options: .atomic)
        }
    }

    // MARK: - The cases

    static var cases: [(String, SharedFixtureInput)] {
        let stockholm = TimeZone(identifier: "Europe/Stockholm")!
        let everySection = ReportDefinition(name: "Shared fixture", range: .custom(S.interval), sections: ReportSection.allCases)
        let metadata = ReportMetadata(appName: "Trio", appVersion: "1.0", cgm: "Dexcom G7", pump: "Omnipod DASH",
                                      settings: [.init("Closed loop", "On")])

        func golden(_ dataset: TherapyDataset, schedule: BasalSchedule? = S.schedule) -> SharedFixtureInput {
            SharedFixtureInput(now: S.end, definition: everySection, dataset: dataset, basalSchedule: schedule,
                               therapySettings: settings, metadata: metadata)
        }

        // Pump history with duplicates, an implausible value, a future reading and negative amounts.
        var dirty = S.dataset()
        dirty.glucose += [
            GlucoseReading(date: S.at(day: 0, 0, 50).addingTimeInterval(10), mgdL: 100, sourceID: "g10"),
            GlucoseReading(date: S.at(day: 0, 3, 2), mgdL: 900, sourceID: "bad"),
            GlucoseReading(date: S.end.addingTimeInterval(3600), mgdL: 120, sourceID: "future"),
        ]
        dirty.insulin += [
            .bolus(at: S.at(day: 0, 7, 30).addingTimeInterval(5), units: 5, sourceID: "b1"),
            .bolus(at: S.at(day: 1, 12), units: -3, sourceID: "negative"),
            .basal(start: S.at(day: 1, 2), end: S.at(day: 1, 3), ratePerHour: 14, sourceID: "too-high"),
        ]
        dirty.carbs += [
            CarbIntake(date: S.at(day: 0, 12, 30).addingTimeInterval(5), grams: 60, sourceID: "c2"),
            CarbIntake(date: S.at(day: 1, 15), grams: -20, sourceID: "negative-carbs"),
            CarbIntake(date: S.at(day: 1, 16), grams: 300, sourceID: "huge"),
        ]

        // The app was installed at the start of day 2: no basal may be invented for day 1.
        let installed = S.at(day: 1, 0)
        let late = S.dataset().restricted(to: DateInterval(start: installed, end: S.end))
        let lateInstall = TherapyDataset(interval: S.interval, source: late.source, glucose: late.glucose, insulin: late.insulin, carbs: late.carbs)

        // mmol/L values delivered as mg/dL.
        var wrongUnits = S.dataset()
        wrongUnits.glucose = wrongUnits.glucose.map { GlucoseReading(date: $0.date, mgdL: $0.mgdL / GlucoseUnit.mgdLPerMmolL, sourceID: $0.sourceID) }

        // A week across the change to summer time in Stockholm (2026-03-29), made five hours before
        // the range ends, with a three-rate schedule and half-hour AGP buckets.
        var generator = SyntheticTherapyGenerator(seed: 7, days: 7)
        generator.timeZone = stockholm
        generator.start = Date(timeIntervalSince1970: 1_774_479_600) // 2026-03-26 00:00 in Stockholm
        let week = generator.makeDataset(app: .trio)
        let weekNow = generator.interval.end.addingTimeInterval(-5 * 3600)
        let soFar = week.restricted(to: DateInterval(start: generator.interval.start, end: weekNow))
        var summerTime = SharedFixtureInput(
            now: weekNow,
            definition: ReportDefinition(name: "Week", range: .lastDays(7), sections: ReportDefinition.defaultSections),
            dataset: TherapyDataset(interval: generator.interval, source: DataSourceInfo(app: .trio, appVersion: "0.5", displayUnit: .mmolL, timeZone: stockholm),
                                    glucose: soFar.glucose, insulin: soFar.insulin, carbs: soFar.carbs),
            basalSchedule: BasalSchedule(entries: [.init(startOffset: 0, ratePerHour: 0.6), .init(startOffset: 6 * 3600.0, ratePerHour: 0.9),
                                                   .init(startOffset: 22 * 3600.0, ratePerHour: 0.7)], timeZone: stockholm),
            agpBucketMinutes: 30
        )
        summerTime.thresholds = GlucoseThresholds(veryLow: 54, low: 70, high: 180, veryHigh: 250, tightHigh: 140)

        // Stockholm clock and mmol/L display on the golden data, with a schedule that varies by hour.
        let stockholmSchedule = BasalSchedule(entries: [.init(startOffset: 0, ratePerHour: 0.8), .init(startOffset: 6 * 3600.0, ratePerHour: 1.2),
                                                        .init(startOffset: 22 * 3600.0, ratePerHour: 0.9)], timeZone: stockholm)

        let nothing = SharedFixtureInput(
            now: S.end,
            definition: ReportDefinition(name: "", range: .custom(DateInterval(start: S.at(day: 1, 0), end: S.end)), sections: ReportSection.allCases),
            dataset: TherapyDataset(interval: DateInterval(start: S.at(day: 1, 0), end: S.end), source: DataSourceInfo(app: .loop, timeZone: S.utc))
        )

        return [
            ("golden-utc", golden(S.dataset())),
            ("golden-stockholm-mmol", golden(S.dataset(timeZone: stockholm, unit: .mmolL), schedule: stockholmSchedule)),
            ("dirty-data", golden(dirty)),
            ("late-install", golden(lateInstall)),
            ("mmol-delivered-as-mgdl", golden(wrongUnits, schedule: nil)),
            ("summer-time-week", summerTime),
            ("no-data", nothing),
        ]
    }

    private static var settings: TherapySettingsSnapshot {
        TherapySettingsSnapshot(
            carbRatios: [.init(startOffset: 0, value: 10), .init(startOffset: 11 * 3600.0, value: 12)],
            insulinSensitivities: [.init(startOffset: 0, value: 50), .init(startOffset: 6 * 3600.0, value: 45)],
            targets: [.init(startOffset: 0, low: 100, high: 110), .init(startOffset: 7 * 3600.0, low: 95, high: 105)],
            groups: [.init("Limits", [.init("Max bolus", "10 U"), .init("Max basal", "3 U/h")])]
        )
    }
}
