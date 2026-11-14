import AIDReportHealthKit
import AIDReportKit
import AIDReportNightscout
import Foundation

/// A two-day scenario whose every statistic can be worked out by hand.
///
/// **Glucose** (5-minute CGM, 288 readings per day, UTC):
/// - Day 1: 00:00–12:00 at 100, 12:00–24:00 at 200
/// - Day 2: six-hour blocks at 50, 60, 150, 300
///
/// **Insulin** (scheduled basal 1.0 U/h from the profile; only deviations are recorded):
/// - Day 1: temp 2.0 U/h set 06:00 for 120 min, superseded 07:00 by 0.5 U/h for 60 min
///   → 06–07 delivers 2.0 U, 07–08 delivers 0.5 U
/// - Day 2: pump suspended 10:00–11:00; temp 3.0 U/h set 20:00 for 60 min, cancelled 20:20 → 1.0 U
/// - Boluses day 1: manual 5 + 6 + 7, SMB 4 × 0.5, external 2. Day 2: manual 4, SMB 2 × 0.25
///
/// **Carbs**: day 1: 40, 60, 80 (the 80 has 10 g fat, 20 g protein) plus a 15 g fat/protein
/// equivalent; day 2: 50.
enum GoldenScenario {
    static let utc = TimeZone(identifier: "UTC")!
    /// 2026-01-01 00:00 UTC
    static let start = Date(timeIntervalSince1970: 1_767_225_600)
    static let interval = DateInterval(start: start, duration: 2 * 86400)
    static var end: Date { interval.end }

    static func at(day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        start.addingTimeInterval(Double(day * 86400 + hour * 3600 + minute * 60))
    }

    // MARK: - Raw events

    static let glucoseValues: [Double] = {
        let blocks: [(value: Double, count: Int)] = [(100, 144), (200, 144), (50, 72), (60, 72), (150, 72), (300, 72)]
        return blocks.flatMap { block in [Double](repeating: block.value, count: block.count) }
    }()

    static var glucose: [GlucoseReading] {
        glucoseValues.enumerated().map { index, value in
            GlucoseReading(date: start.addingTimeInterval(Double(index) * 300), mgdL: value, sourceID: "g\(index)")
        }
    }

    struct Bolus { let date: Date; let units: Double; let automatic: Bool; let external: Bool; let id: String }

    static let boluses: [Bolus] = [
        Bolus(date: at(day: 0, 7, 30), units: 5, automatic: false, external: false, id: "b1"),
        Bolus(date: at(day: 0, 12, 30), units: 6, automatic: false, external: false, id: "b2"),
        Bolus(date: at(day: 0, 18, 30), units: 7, automatic: false, external: false, id: "b3"),
        Bolus(date: at(day: 0, 8), units: 0.5, automatic: true, external: false, id: "s1"),
        Bolus(date: at(day: 0, 9), units: 0.5, automatic: true, external: false, id: "s2"),
        Bolus(date: at(day: 0, 10), units: 0.5, automatic: true, external: false, id: "s3"),
        Bolus(date: at(day: 0, 11), units: 0.5, automatic: true, external: false, id: "s4"),
        Bolus(date: at(day: 0, 21), units: 2, automatic: false, external: true, id: "x1"),
        Bolus(date: at(day: 1, 8), units: 4, automatic: false, external: false, id: "b4"),
        Bolus(date: at(day: 1, 9), units: 0.25, automatic: true, external: false, id: "s5"),
        Bolus(date: at(day: 1, 13), units: 0.25, automatic: true, external: false, id: "s6"),
    ]

    static let carbs: [CarbIntake] = [
        CarbIntake(date: at(day: 0, 7, 30), grams: 40, sourceID: "c1"),
        CarbIntake(date: at(day: 0, 12, 30), grams: 60, sourceID: "c2"),
        CarbIntake(date: at(day: 0, 18, 30), grams: 80, fatGrams: 10, proteinGrams: 20, sourceID: "c3"),
        CarbIntake(date: at(day: 0, 19, 30), grams: 15, isFatProteinEquivalent: true, sourceID: "c3-fpu"),
        CarbIntake(date: at(day: 1, 8), grams: 50, sourceID: "c4"),
    ]

    static var schedule: BasalSchedule {
        BasalSchedule(entries: [.init(startOffset: 0, ratePerHour: 1.0)], timeZone: utc)!
    }

    // MARK: - As an app adapter delivers it (pump history: unclosed temp basals, no scheduled basal)

    static var pumpHistoryInsulin: [InsulinDose] {
        boluses.map { .bolus(at: $0.date, units: $0.units, isAutomatic: $0.automatic, isExternal: $0.external, sourceID: $0.id) } + [
            .basal(start: at(day: 0, 6), end: at(day: 0, 8), ratePerHour: 2.0, sourceID: "t1"), // superseded at 07:00
            .basal(start: at(day: 0, 7), end: at(day: 0, 8), ratePerHour: 0.5, sourceID: "t2"),
            InsulinDose(kind: .suspend, start: at(day: 1, 10), end: at(day: 1, 11), units: 0, sourceID: "su1"),
            .basal(start: at(day: 1, 20), end: at(day: 1, 20, 20), ratePerHour: 3.0, sourceID: "t3"), // already cancelled at 20:20
        ]
    }

    static func dataset(timeZone: TimeZone = utc, unit: GlucoseUnit = .mgdL) -> TherapyDataset {
        TherapyDataset(
            interval: interval,
            source: DataSourceInfo(app: .trio, displayUnit: unit, timeZone: timeZone),
            glucose: glucose,
            insulin: pumpHistoryInsulin,
            carbs: carbs
        )
    }

    // MARK: - As Nightscout stores it

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static var nightscoutEntries: [[String: Any]] {
        glucose.map { ["_id": $0.sourceID!, "type": "sgv", "sgv": $0.mgdL, "date": $0.date.timeIntervalSince1970 * 1000] }
    }

    static var nightscoutTreatments: [[String: Any]] {
        var treatments: [[String: Any]] = boluses.map { bolus in
            var record: [String: Any] = ["_id": bolus.id, "created_at": iso(bolus.date), "insulin": bolus.units]
            if bolus.external {
                record["eventType"] = "External Insulin"
            } else if bolus.automatic {
                record["eventType"] = "SMB" // Trio style
            } else {
                record["eventType"] = "Correction Bolus"
                record["automatic"] = false // Loop style
            }
            return record
        }
        treatments += [
            ["_id": "t1", "eventType": "Temp Basal", "created_at": iso(at(day: 0, 6)), "duration": 120, "absolute": 2.0, "rate": 2.0],
            ["_id": "t2", "eventType": "Temp Basal", "created_at": iso(at(day: 0, 7)), "duration": 60, "rate": "0.5"],
            ["_id": "su1", "eventType": "Suspend Pump", "created_at": iso(at(day: 1, 10))],
            ["_id": "re1", "eventType": "Resume Pump", "created_at": iso(at(day: 1, 11))],
            ["_id": "t3", "eventType": "Temp Basal", "created_at": iso(at(day: 1, 20)), "duration": 60, "absolute": 3.0],
            ["_id": "t3-cancel", "eventType": "Temp Basal", "created_at": iso(at(day: 1, 20, 20)), "duration": 0],
            ["_id": "c1", "eventType": "Carb Correction", "created_at": iso(at(day: 0, 7, 30)), "carbs": 40],
            ["_id": "c2", "eventType": "Carb Correction", "created_at": iso(at(day: 0, 12, 30)), "carbs": 60],
            ["_id": "c3", "eventType": "Carb Correction", "created_at": iso(at(day: 0, 18, 30)), "carbs": 80, "fat": 10, "protein": 20, "id": "meal-3", "fpuID": "fpu-3"],
            ["_id": "c3-fpu", "eventType": "Carb Correction", "created_at": iso(at(day: 0, 19, 30)), "carbs": 15, "id": "fpu-3", "fpuID": "fpu-3"],
            ["_id": "c4", "eventType": "Carb Correction", "created_at": iso(at(day: 1, 8)), "carbs": 50],
            ["_id": "note", "eventType": "Note", "created_at": iso(at(day: 1, 9)), "notes": "ignored"],
        ]
        return treatments
    }

    static func nightscoutProfile(timeZone: String = "UTC") -> [[String: Any]] {
        [[
            "defaultProfile": "Default",
            "store": ["Default": ["timezone": timeZone, "basal": [["time": "00:00", "value": 1.0, "timeAsSeconds": 0]]]],
        ]]
    }

    /// A Nightscout source backed by an in-memory "server" that honors date bounds, newest-first
    /// ordering and `count`, so paging is exercised for real.
    static func nightscoutSource(
        pageSize: Int,
        requestLog: RequestLog? = nil,
        dropGlucose: DateInterval? = nil,
        profileTimeZone: String = "UTC"
    ) -> NightscoutTherapyDataSource {
        let entries = nightscoutEntries.filter { record in
            guard let gap = dropGlucose else { return true }
            return !gap.contains(Date(timeIntervalSince1970: (record["date"] as! Double) / 1000))
        }
        let treatments = nightscoutTreatments
        let profile = nightscoutProfile(timeZone: profileTimeZone)
        return NightscoutTherapyDataSource(
            configuration: NightscoutConfiguration(baseURL: URL(string: "https://ns.example.test")!, pageSize: pageSize),
            info: DataSourceInfo(app: .nightscout, timeZone: utc),
            transport: { request in
                await requestLog?.record(request)
                let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                let count = Int(query["count"] ?? "") ?? 10
                let body: Any
                if components.path.hasSuffix("entries.json") {
                    let lower = Double(query["find[date][$gte]"]!)!
                    let inclusive = query["find[date][$lte]"].flatMap(Double.init)
                    let upper = inclusive ?? Double(query["find[date][$lt]"]!)!
                    body = Array(entries
                        .filter { let d = $0["date"] as! Double; return d >= lower && (d < upper || (inclusive != nil && d == upper)) }
                        .sorted { ($0["date"] as! Double) > ($1["date"] as! Double) }
                        .prefix(count))
                } else if components.path.hasSuffix("treatments.json") {
                    let lower = query["find[created_at][$gte]"]!
                    let inclusive = query["find[created_at][$lte]"]
                    let upper = inclusive ?? query["find[created_at][$lt]"]!
                    body = Array(treatments
                        .filter { let d = $0["created_at"] as! String; return d >= lower && (d < upper || (inclusive != nil && d == upper)) }
                        .sorted { ($0["created_at"] as! String) > ($1["created_at"] as! String) }
                        .prefix(count))
                } else {
                    body = profile
                }
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (try JSONSerialization.data(withJSONObject: body), response)
            }
        )
    }

    // MARK: - As Apple Health stores it (Loop style: every basal segment as delivered)

    static var healthGlucose: [HealthSample] {
        glucose.map { HealthSample(start: $0.date, value: $0.mgdL, syncIdentifier: $0.sourceID) }
    }

    static var healthInsulin: [HealthSample] {
        func basal(_ from: Date, _ to: Date, rate: Double, automatic: Bool = false, suspend: Bool = false) -> HealthSample {
            HealthSample(start: from, end: to, value: rate * to.timeIntervalSince(from) / 3600,
                         insulinDeliveryReason: .basal, isAutomatic: automatic, isSuspend: suspend)
        }
        return boluses.map {
            HealthSample(start: $0.date, value: $0.units, syncIdentifier: $0.id, insulinDeliveryReason: .bolus,
                         isAutomatic: $0.automatic, isManuallyEntered: $0.external)
        } + [
            basal(at(day: 0, 0), at(day: 0, 6), rate: 1),
            basal(at(day: 0, 6), at(day: 0, 7), rate: 2, automatic: true),
            basal(at(day: 0, 7), at(day: 0, 8), rate: 0.5, automatic: true),
            basal(at(day: 0, 8), at(day: 1, 10), rate: 1),
            basal(at(day: 1, 10), at(day: 1, 11), rate: 0, suspend: true),
            basal(at(day: 1, 11), at(day: 1, 20), rate: 1),
            basal(at(day: 1, 20), at(day: 1, 20, 20), rate: 3, automatic: true),
            basal(at(day: 1, 20, 20), at(day: 2, 0), rate: 1),
        ]
    }

    /// Health holds real carbs only: Trio writes fat/protein as separate nutrient samples.
    static var healthCarbs: [HealthSample] {
        carbs.filter { !$0.isFatProteinEquivalent }.map { HealthSample(start: $0.date, value: $0.grams, syncIdentifier: $0.sourceID) }
    }
}

actor RequestLog {
    private(set) var paths: [String] = []
    func record(_ request: URLRequest) { paths.append(request.url?.path ?? "") }
    func count(containing text: String) -> Int { paths.filter { $0.contains(text) }.count }
}
