import AIDReportKit
import Foundation

public struct NightscoutConfiguration: Sendable {
    public var baseURL: URL
    /// Access token (Admin → Subjects). Sent as the `token` query parameter.
    public var token: String?
    /// Records per request. Requests are repeated, walking back in time, until a page comes back
    /// short, so long ranges and 1-minute sensors are not cut off.
    public var pageSize: Int
    /// Safety stop for the paging loop.
    public var maximumPages: Int
    /// Treatments are fetched from this far before the interval so a temp basal that started
    /// earlier and runs into it is included (the pipeline clamps it).
    public var treatmentLookback: TimeInterval

    public init(baseURL: URL, token: String? = nil, pageSize: Int = 10000, maximumPages: Int = 100, treatmentLookback: TimeInterval = 6 * 3600) {
        self.baseURL = baseURL
        self.token = token
        self.pageSize = max(1, pageSize)
        self.maximumPages = max(1, maximumPages)
        self.treatmentLookback = treatmentLookback
    }
}

public enum NightscoutError: Error, LocalizedError {
    case invalidURL(String)
    case httpStatus(Int, url: URL?)

    public var errorDescription: String? {
        switch self {
        case let .invalidURL(path):
            return String(localized: "Could not build a Nightscout URL for \(path)", bundle: .module,
                          comment: "Nightscout error; the argument is an API path")
        case let .httpStatus(status, url):
            return String(localized: "Nightscout returned HTTP \(status) for \(url?.path ?? "/")", bundle: .module,
                          comment: "Nightscout error; arguments are an HTTP status code and an API path")
        }
    }
}

/// The parts of a Nightscout profile a report uses.
public struct NightscoutProfile: Sendable {
    public var basalSchedule: BasalSchedule?
    /// The looping phone's time zone; `nil` when the profile does not name one.
    public var timeZone: TimeZone?

    public init(basalSchedule: BasalSchedule? = nil, timeZone: TimeZone? = nil) {
        self.basalSchedule = basalSchedule
        self.timeZone = timeZone
    }
}

/// Reads glucose, treatments and the basal profile from a Nightscout site.
/// Works for any uploader (Loop, Trio, AAPS), which makes it the default source for LoopFollow.
public final class NightscoutTherapyDataSource: TherapyDataSource {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public let configuration: NightscoutConfiguration
    public let info: DataSourceInfo
    private let transport: Transport

    /// `transport` defaults to `URLSession.shared`; inject one in tests.
    public init(configuration: NightscoutConfiguration, info: DataSourceInfo = DataSourceInfo(app: .nightscout), transport: Transport? = nil) {
        self.configuration = configuration
        self.info = info
        self.transport = transport ?? { try await URLSession.shared.data(for: $0) }
    }

    public func glucose(in interval: DateInterval) async throws -> [GlucoseReading] {
        let lower = String(Int64(interval.start.timeIntervalSince1970 * 1000))
        let records = try await pages(
            "api/v1/entries.json",
            lowerBound: ("find[date][$gte]", lower),
            upperField: "find[date]",
            firstUpper: String(Int64(interval.end.timeIntervalSince1970 * 1000)),
            // Nightscout returns newest first; continue below the oldest record of the page.
            nextUpper: { page in page.compactMap { ($0["date"] as? NSNumber)?.int64Value }.min().map(String.init) }
        )
        return try NightscoutParser.glucose(fromEntries: JSONSerialization.data(withJSONObject: records))
    }

    public func insulin(in interval: DateInterval) async throws -> [InsulinDose] {
        try await treatments(in: interval).insulin
    }

    public func carbs(in interval: DateInterval) async throws -> [CarbIntake] {
        try await treatments(in: interval).carbs
    }

    /// One treatments request for both insulin and carbs.
    public func dataset(in interval: DateInterval) async throws -> TherapyDataset {
        let glucose = try await glucose(in: interval)
        let treatments = try await treatments(in: interval)
        return TherapyDataset(interval: interval, source: info, glucose: glucose, insulin: treatments.insulin, carbs: treatments.carbs)
    }

    public func treatments(in interval: DateInterval) async throws -> (insulin: [InsulinDose], carbs: [CarbIntake]) {
        let records = try await pages(
            "api/v1/treatments.json",
            lowerBound: ("find[created_at][$gte]", NightscoutParser.iso8601(interval.start.addingTimeInterval(-configuration.treatmentLookback))),
            upperField: "find[created_at]",
            firstUpper: NightscoutParser.iso8601(interval.end),
            nextUpper: { page in page.compactMap { $0["created_at"] as? String }.min() }
        )
        // All pages are parsed together so cancel/resume records pair up across page boundaries.
        return try NightscoutParser.treatments(from: JSONSerialization.data(withJSONObject: records), openSuspendEnd: interval.end)
    }

    /// The site's current basal schedule; pass it as `ReportOptions.basalSchedule`.
    public func basalSchedule(profileName: String? = nil) async throws -> BasalSchedule? {
        try await profile(profileName: profileName).basalSchedule
    }

    /// What a report needs from the site's current profile, in one request: the basal schedule
    /// and the time zone of the looping phone.
    public func profile(profileName: String? = nil, now: Date = Date()) async throws -> NightscoutProfile {
        let data = try await currentProfile(now: now)
        return NightscoutProfile(
            basalSchedule: try NightscoutParser.basalSchedule(fromProfile: data, profileName: profileName),
            timeZone: try NightscoutParser.timeZone(fromProfile: data, profileName: profileName)
        )
    }

    /// The newest profile record that has already started, asked for the way LoopFollow asks
    /// (`profiles.json` with a `startDate` filter), so a profile dated in the future is not taken
    /// for the current one. A site that does not answer that query is asked for its newest record.
    private func currentProfile(now: Date) async throws -> Data {
        let started = ("find[startDate][$lte]", NightscoutParser.iso8601(now.addingTimeInterval(60)))
        if let data = try? await get("api/v1/profiles.json", query: [("count", "1"), started]),
           let records = try? JSONSerialization.jsonObject(with: data) as? [Any], !records.isEmpty
        {
            return data
        }
        return try await get("api/v1/profile.json", query: [("count", "1")])
    }

    /// The same source reporting in `timeZone`. A follower in another time zone uses this with
    /// `profile().timeZone`, so days, times of day and midnight are the looper's, not its own.
    public func usingTimeZone(_ timeZone: TimeZone) -> NightscoutTherapyDataSource {
        var info = self.info
        info.timeZoneIdentifier = timeZone.identifier
        return NightscoutTherapyDataSource(configuration: configuration, info: info, transport: transport)
    }

    // MARK: - HTTP

    func request(_ path: String, query: [(String, String)]) throws -> URLRequest {
        guard var components = URLComponents(url: configuration.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw NightscoutError.invalidURL(path)
        }
        var items = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        if let token = configuration.token, !token.isEmpty {
            items.append(URLQueryItem(name: "token", value: token))
        }
        components.queryItems = items
        guard let url = components.url else { throw NightscoutError.invalidURL(path) }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60
        // Always the site's current data: a cached profile or page would silently go stale.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    /// Fetches `path` page by page, moving the upper bound down until a page is short.
    ///
    /// Later pages include the boundary timestamp (`$lte`) because several records can share it
    /// (a bolus and a carb entry logged together); the overlap is removed again by identity.
    private func pages(
        _ path: String,
        lowerBound: (String, String),
        upperField: String,
        firstUpper: String,
        nextUpper: ([[String: Any]]) -> String?
    ) async throws -> [[String: Any]] {
        var records: [[String: Any]] = []
        var seen = Set<String>()
        var upper = (key: "\(upperField)[$lt]", value: firstUpper)
        for _ in 0 ..< configuration.maximumPages {
            let data = try await get(path, query: [lowerBound, upper, ("count", String(configuration.pageSize))])
            let page = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
            let fresh = page.filter { seen.insert(Self.identity(of: $0)).inserted }
            records += fresh
            // No new records means the whole page shares one timestamp: stop rather than loop.
            guard page.count >= configuration.pageSize, !fresh.isEmpty, let next = nextUpper(page) else { break }
            upper = (key: "\(upperField)[$lte]", value: next)
        }
        return records
    }

    private static func identity(of record: [String: Any]) -> String {
        if let id = record["_id"] as? String, !id.isEmpty { return id }
        let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? UUID().uuidString
    }

    private func get(_ path: String, query: [(String, String)]) async throws -> Data {
        let request = try request(path, query: query)
        let (data, response) = try await transport(request)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw NightscoutError.httpStatus(http.statusCode, url: request.url)
        }
        return data
    }
}
