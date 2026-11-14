import AIDReportKit
@testable import AIDReportNightscout
import XCTest

private let t0 = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01 00:00 UTC

private func fixture(_ name: String) throws -> Data {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private actor RequestLog {
    var requests: [URLRequest] = []
    func append(_ request: URLRequest) { requests.append(request) }
}

final class NightscoutParserTests: XCTestCase {
    func testEntries() throws {
        let readings = try NightscoutParser.glucose(fromEntries: fixture("entries"))
        XCTAssertEqual(readings.filter { $0.kind == .sensor }.map(\.mgdL), [120, 125, 130])
        XCTAssertEqual(readings.filter { $0.kind == .fingerstick }.map(\.mgdL), [118])
        XCTAssertFalse(readings.contains { $0.sourceID == "e4" }, "calibration records are skipped")
        XCTAssertEqual(readings.first { $0.sourceID == "e5" }?.date, t0.addingTimeInterval(600))
    }

    func testTreatments() throws {
        let (insulin, carbs) = try NightscoutParser.treatments(from: fixture("treatments"))

        let temps = insulin.filter { $0.kind == .tempBasal }
        XCTAssertEqual(temps.count, 2)
        XCTAssertEqual(temps[0].end, t0.addingTimeInterval(300), "superseded temp basal ends when the next starts")
        XCTAssertEqual(temps[0].units, 1.2 * 5 / 60, accuracy: 1e-9)
        XCTAssertEqual(temps[1].units, 0.6 * 0.5, accuracy: 1e-9)

        let suspend = try XCTUnwrap(insulin.first { $0.kind == .suspend })
        XCTAssertEqual(suspend.duration, 45 * 60)
        XCTAssertEqual(suspend.units, 0)

        let boluses = Dictionary(uniqueKeysWithValues: insulin.filter { $0.kind == .bolus }.map { ($0.sourceID!, $0) })
        XCTAssertEqual(boluses.count, 5)
        XCTAssertEqual(boluses["t3"]?.isAutomatic, true)
        XCTAssertEqual(boluses["t4"]?.isAutomatic, false)
        XCTAssertEqual(boluses["t5"]?.isAutomatic, true)
        XCTAssertEqual(boluses["t10"]?.isExternal, true)
        XCTAssertEqual(boluses["t12"]?.units, 1.5)
        XCTAssertEqual(boluses["t12"]?.start, t0.addingTimeInterval(12 * 3600))

        XCTAssertEqual(carbs.count, 3)
        XCTAssertEqual(carbs.first { $0.sourceID == "t4" }?.absorptionTime, 3 * 3600)
        let meal = try XCTUnwrap(carbs.first { $0.sourceID == "t6" })
        XCTAssertFalse(meal.isFatProteinEquivalent)
        XCTAssertEqual(meal.fatGrams, 20)
        XCTAssertEqual(carbs.first { $0.sourceID == "t7" }?.isFatProteinEquivalent, true)
    }

    func testProfileBasalSchedule() throws {
        let schedule = try XCTUnwrap(NightscoutParser.basalSchedule(fromProfile: fixture("profile")))
        XCTAssertEqual(schedule.timeZoneIdentifier, "Europe/Stockholm")
        XCTAssertEqual(schedule.entries.map(\.startOffset), [0, 6 * 3600, 22 * 3600] as [TimeInterval])
        XCTAssertEqual(schedule.dailyTotal, 0.8 * 6 + 1.1 * 16 + 0.9 * 2, accuracy: 1e-9)

        let other = try XCTUnwrap(NightscoutParser.basalSchedule(fromProfile: fixture("profile"), profileName: "Other"))
        XCTAssertEqual(other.dailyTotal, 48, accuracy: 1e-9)
    }
}

final class NightscoutDataSourceTests: XCTestCase {
    private func source(status: Int = 200, log: RequestLog) -> NightscoutTherapyDataSource {
        NightscoutTherapyDataSource(
            configuration: NightscoutConfiguration(baseURL: URL(string: "https://ns.example.test")!, token: "reader-abc123"),
            transport: { request in
                await log.append(request)
                let path = request.url?.path ?? ""
                let name = path.contains("entries") ? "entries" : path.contains("treatments") ? "treatments" : "profile"
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                return (try fixture(name), response)
            }
        )
    }

    private func query(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    func testTimeZoneNamesFromEveryUploader() throws {
        // Trio and AAPS write region names.
        XCTAssertEqual(NightscoutParser.timeZone(named: "Europe/Stockholm")?.identifier, "Europe/Stockholm")
        XCTAssertEqual(NightscoutParser.timeZone(named: "europe/stockholm")?.identifier, "Europe/Stockholm")
        // Loop writes a fixed offset in capitals; "ETC/GMT-1" is one hour AHEAD of UTC.
        let loop = try XCTUnwrap(NightscoutParser.timeZone(named: "ETC/GMT-1"))
        XCTAssertEqual(loop.secondsFromGMT(), 3600)
        XCTAssertEqual(NightscoutParser.timeZone(named: "ETC/GMT+7")?.secondsFromGMT(), -7 * 3600)
        XCTAssertEqual(NightscoutParser.timeZone(named: "Etc/GMT-1")?.secondsFromGMT(), 3600)
        // Plain offsets.
        XCTAssertEqual(NightscoutParser.timeZone(named: "+01:00")?.secondsFromGMT(), 3600)
        XCTAssertEqual(NightscoutParser.timeZone(named: "-0700")?.secondsFromGMT(), -7 * 3600)
        XCTAssertEqual(NightscoutParser.timeZone(named: "UTC+1")?.secondsFromGMT(), 3600)
        XCTAssertEqual(NightscoutParser.timeZone(named: "GMT-3:30")?.secondsFromGMT(), -(3 * 3600 + 1800))
        XCTAssertEqual(NightscoutParser.timeZone(named: "UTC")?.secondsFromGMT(), 0)
        // Nothing usable.
        XCTAssertNil(NightscoutParser.timeZone(named: ""))
        XCTAssertNil(NightscoutParser.timeZone(named: "Mars/Olympus"))
        XCTAssertNil(NightscoutParser.timeZone(named: "+99:00"))
    }

    func testLoopProfileKeepsTheLoopersTimeZone() throws {
        // As Loop uploads it: basal times are the looper's local times, zone as "ETC/GMT-1".
        let profile = Data("""
        [{"defaultProfile": "Default", "store": {"Default": {
            "timezone": "ETC/GMT-1",
            "basal": [{"time": "00:00", "timeAsSeconds": 0, "value": 1.0}, {"time": "06:00", "timeAsSeconds": 21600, "value": 2.0}]
        }}}]
        """.utf8)
        XCTAssertEqual(try NightscoutParser.timeZone(fromProfile: profile)?.secondsFromGMT(), 3600)
        let schedule = try XCTUnwrap(NightscoutParser.basalSchedule(fromProfile: profile))
        XCTAssertEqual(TimeZone(identifier: schedule.timeZoneIdentifier)?.secondsFromGMT(), 3600)

        // 05:00–07:00 on the looper's clock is 04:00–06:00 UTC: one hour at 1 U/h, one at 2 U/h.
        let start = Date(timeIntervalSince1970: 1_767_225_600 + 4 * 3600) // 2026-01-01 04:00 UTC
        let doses = schedule.doses(in: DateInterval(start: start, duration: 2 * 3600))
        XCTAssertEqual(doses.reduce(0) { $0 + $1.units }, 3.0, accuracy: 1e-9)
    }

    func testProfileWithoutTimeZone() throws {
        let profile = Data(#"[{"defaultProfile": "Default", "store": {"Default": {"basal": [{"time": "00:00", "value": 1.0}]}}}]"#.utf8)
        XCTAssertNil(try NightscoutParser.timeZone(fromProfile: profile))
    }

    func testDatasetUsesOneEntriesAndOneTreatmentsRequest() async throws {
        let log = RequestLog()
        let interval = DateInterval(start: t0, duration: 86400)
        let data = try await source(log: log).dataset(in: interval)
        XCTAssertEqual(data.glucose.count, 4)
        XCTAssertEqual(data.carbs.count, 3)

        let requests = await log.requests
        XCTAssertEqual(requests.map { $0.url!.path }, ["/api/v1/entries.json", "/api/v1/treatments.json"])

        let entries = query(requests[0])
        XCTAssertEqual(entries["find[date][$gte]"], "1767225600000")
        XCTAssertEqual(entries["find[date][$lt]"], "1767312000000")
        XCTAssertEqual(entries["token"], "reader-abc123")
        XCTAssertNotNil(entries["count"])

        let treatments = query(requests[1])
        XCTAssertEqual(treatments["find[created_at][$gte]"], "2025-12-31T18:00:00.000Z", "includes the 6 h temp-basal lookback")
    }

    func testHTTPErrorThrows() async {
        do {
            _ = try await source(status: 401, log: RequestLog()).glucose(in: DateInterval(start: t0, duration: 3600))
            XCTFail("Expected an HTTP error")
        } catch let NightscoutError.httpStatus(status, _) {
            XCTAssertEqual(status, 401)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testProfileRequestAsksForTheProfileInForceNow() async throws {
        let log = RequestLog()
        let schedule = try await source(log: log).profile(now: t0).basalSchedule
        XCTAssertNotNil(schedule)

        // Asked the way LoopFollow asks: newest record whose start date has passed.
        let requests = await log.requests
        XCTAssertEqual(requests.map { $0.url?.path }, ["/api/v1/profiles.json"])
        let profile = query(requests[0])
        XCTAssertEqual(profile["count"], "1")
        XCTAssertEqual(profile["find[startDate][$lte]"], "2026-01-01T00:01:00.000Z")
        XCTAssertEqual(requests[0].cachePolicy, .reloadIgnoringLocalCacheData, "never a cached profile")
    }

    func testProfileFallsBackToTheNewestRecord() async throws {
        // A site that answers the filtered query with nothing (or not at all) is asked plainly.
        for unanswered in [(status: 200, body: Data("[]".utf8)), (status: 404, body: Data())] {
            let log = RequestLog()
            let site = NightscoutTherapyDataSource(
                configuration: NightscoutConfiguration(baseURL: URL(string: "https://ns.example.test")!),
                transport: { request in
                    await log.append(request)
                    let filtered = request.url?.path.hasSuffix("profiles.json") == true
                    let response = HTTPURLResponse(url: request.url!, statusCode: filtered ? unanswered.status : 200, httpVersion: nil, headerFields: nil)!
                    return (filtered ? unanswered.body : try fixture("profile"), response)
                }
            )
            let profile = try await site.profile()
            XCTAssertEqual(profile.timeZone?.identifier, "Europe/Stockholm")
            XCTAssertNotNil(profile.basalSchedule)
            let paths = await log.requests.map { $0.url?.path }
            XCTAssertEqual(paths, ["/api/v1/profiles.json", "/api/v1/profile.json"])
        }
    }
}

final class NightscoutSuspensionTests: XCTestCase {
    private func treatment(_ eventType: String, at offset: TimeInterval, _ fields: String = "") -> String {
        let created = ISO8601DateFormatter().string(from: t0.addingTimeInterval(offset))
        return #"{"eventType": "\#(eventType)", "created_at": "\#(created)"\#(fields.isEmpty ? "" : ", " + fields)}"#
    }

    private func insulin(_ treatments: [String], openSuspendEnd: Date? = nil) throws -> [InsulinDose] {
        try NightscoutParser.treatments(from: Data("[\(treatments.joined(separator: ","))]".utf8), openSuspendEnd: openSuspendEnd).insulin
    }

    func testTrioUploadsSuspensionsAsNotes() throws {
        // Trio: eventType "Note", notes "PumpSuspend" / "PumpResume". Any other note is just a note.
        let doses = try insulin([
            treatment("Note", at: 1800, #""notes": "Suspend the pump before swimming""#),
            treatment("Note", at: 3600, #""notes": "PumpSuspend""#),
            treatment("Note", at: 3600 + 45 * 60, #""notes": "PumpResume""#),
        ])
        XCTAssertEqual(doses.map(\.kind), [.suspend])
        XCTAssertEqual(doses[0].start, t0.addingTimeInterval(3600))
        XCTAssertEqual(doses[0].duration, 45 * 60)
    }

    func testSuspensionWithoutResumeEndsAtTheNextTempBasal() throws {
        // The resume never reached the site. The pump demonstrably ran again at 02:00, so the
        // suspension ends there instead of wiping out basal until the end of the report.
        let doses = try insulin([
            treatment("Suspend Pump", at: 3600),
            treatment("Temp Basal", at: 7200, #""duration": 30, "absolute": 1.2"#),
        ], openSuspendEnd: t0.addingTimeInterval(86400))

        let suspend = try XCTUnwrap(doses.first { $0.kind == .suspend })
        XCTAssertEqual(suspend.start, t0.addingTimeInterval(3600))
        XCTAssertEqual(suspend.end, t0.addingTimeInterval(7200))
        let temp = try XCTUnwrap(doses.first { $0.kind == .tempBasal })
        XCTAssertEqual(temp.units, 0.6, accuracy: 1e-9, "the temp basal after it is delivered in full")
    }

    func testSuspensionStillRunningLastsToTheEndOfTheReport() throws {
        // Suspended twice without a resume or a temp basal in between: one suspension from the first.
        let doses = try insulin([
            treatment("Temp Basal", at: 0, #""duration": 30, "absolute": 1.0"#),
            treatment("Note", at: 3600, #""notes": "PumpSuspend""#),
            treatment("Note", at: 5400, #""notes": "PumpSuspend""#),
        ], openSuspendEnd: t0.addingTimeInterval(4 * 3600))

        let suspends = doses.filter { $0.kind == .suspend }
        XCTAssertEqual(suspends.count, 1)
        XCTAssertEqual(suspends[0].start, t0.addingTimeInterval(3600))
        XCTAssertEqual(suspends[0].end, t0.addingTimeInterval(4 * 3600))
    }
}
