import AIDReportKit
import Foundation

/// Parses Nightscout API v1 JSON (`entries`, `treatments`, `profile`) into AIDReportKit models.
///
/// Lenient by design: Loop, Trio, AAPS and uploader apps disagree on number-vs-string fields,
/// date fields and event type names. Unknown records are skipped rather than failing the batch.
public enum NightscoutParser {
    // MARK: - Entries

    public static func glucose(fromEntries data: Data) throws -> [GlucoseReading] {
        try JSONDecoder().decode([Entry].self, from: data).compactMap { entry in
            guard let date = entry.resolvedDate else { return nil }
            switch entry.type?.lowercased() {
            case "mbg":
                return entry.mbg.map { GlucoseReading(date: date, mgdL: $0, kind: .fingerstick, sourceID: entry.id) }
            case "sgv":
                return entry.sgv.map { GlucoseReading(date: date, mgdL: $0, kind: .sensor, sourceID: entry.id) }
            case nil:
                // Typeless records: whichever value is present decides.
                if let sgv = entry.sgv { return GlucoseReading(date: date, mgdL: sgv, kind: .sensor, sourceID: entry.id) }
                return entry.mbg.map { GlucoseReading(date: date, mgdL: $0, kind: .fingerstick, sourceID: entry.id) }
            default:
                return nil // "cal" and anything else
            }
        }
    }

    // MARK: - Treatments

    /// - Parameter openSuspendEnd: where a suspension with neither a resume nor a later temp
    ///   basal is taken to end (normally the end of the requested interval): the pump is still
    ///   suspended. `nil` drops such suspensions.
    public static func treatments(from data: Data, openSuspendEnd: Date? = nil) throws -> (insulin: [InsulinDose], carbs: [CarbIntake]) {
        let treatments = try JSONDecoder().decode([Treatment].self, from: data)
            .filter { $0.resolvedDate != nil }
            .sorted { $0.resolvedDate! < $1.resolvedDate! }

        var insulin: [InsulinDose] = []
        var carbs: [CarbIntake] = []
        var openSuspend: (date: Date, id: String?)?

        for t in treatments {
            let date = t.resolvedDate!
            let event = t.eventType?.lowercased() ?? ""
            // Loop uploads "Suspend Pump" / "Resume Pump" treatments; Trio uploads a "Note" whose
            // text is exactly "PumpSuspend" / "PumpResume".
            let note = t.notes?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let isSuspend = event.contains("suspend") || note == "pumpsuspend"
            let isResume = event.contains("resume") || note == "pumpresume"

            if event == "temp basal", let minutes = t.durationMinutes, minutes > 0, let rate = t.absolute ?? t.rate {
                // A pump that runs a temp basal is no longer suspended: a suspension whose resume
                // was never uploaded ends here (as LoopFollow reads it), not at the end of the report.
                if let suspend = openSuspend, date > suspend.date {
                    insulin.append(InsulinDose(kind: .suspend, start: suspend.date, end: date, units: 0, sourceID: suspend.id))
                    openSuspend = nil
                }
                insulin.append(.basal(.tempBasal, start: date, end: date.addingTimeInterval(minutes * 60),
                                      ratePerHour: rate, isAutomatic: t.automatic ?? true, sourceID: t.id))
            } else if event == "temp basal", (t.durationMinutes ?? 0) <= 0 {
                // Duration 0 cancels the running temp basal (Loop, AAPS): end it here.
                if let running = insulin.lastIndex(where: { $0.kind == .tempBasal }), insulin[running].end > date {
                    insulin[running] = insulin[running].ending(at: date)
                }
            } else if isSuspend {
                if let minutes = t.durationMinutes, minutes > 0 {
                    insulin.append(InsulinDose(kind: .suspend, start: date, end: date.addingTimeInterval(minutes * 60), units: 0, isAutomatic: t.automatic ?? false, sourceID: t.id))
                } else if openSuspend == nil {
                    // A repeated suspend while already suspended keeps the earlier start.
                    openSuspend = (date, t.id)
                }
            } else if isResume, let suspend = openSuspend {
                insulin.append(InsulinDose(kind: .suspend, start: suspend.date, end: date, units: 0, sourceID: suspend.id))
                openSuspend = nil
            }

            if let units = t.insulin, units > 0 {
                let isAutomatic = t.automatic == true || t.isSMB == true || event == "smb" || t.type?.lowercased() == "smb"
                insulin.append(.bolus(at: date, units: units, isAutomatic: isAutomatic,
                                      isExternal: event == "external insulin", sourceID: t.id))
            }

            if let grams = t.carbs, grams > 0 {
                // Trio uploads fat/protein carb equivalents with `id == fpuID`; the meal itself has its own id.
                let isEquivalent = t.fpuID != nil && t.fpuID == t.trioID
                carbs.append(CarbIntake(
                    date: date,
                    grams: grams,
                    absorptionTime: t.absorptionTime.map { $0 * 60 },
                    fatGrams: isEquivalent ? nil : t.fat,
                    proteinGrams: isEquivalent ? nil : t.protein,
                    isFatProteinEquivalent: isEquivalent,
                    sourceID: t.id
                ))
            }
        }

        if let suspend = openSuspend, let end = openSuspendEnd, end > suspend.date {
            insulin.append(InsulinDose(kind: .suspend, start: suspend.date, end: end, units: 0, sourceID: suspend.id))
        }

        // Temp basals are recorded as replacing each other without being closed.
        return (BasalTimeline.truncatingOverlaps(insulin), carbs)
    }

    // MARK: - Profile

    /// Basal schedule from `/api/v1/profile.json` (first document; `profileName` defaults to its `defaultProfile`).
    public static func basalSchedule(fromProfile data: Data, profileName: String? = nil) throws -> BasalSchedule? {
        let documents = try JSONDecoder().decode([ProfileDocument].self, from: data)
        guard let document = documents.first,
              let name = profileName ?? document.defaultProfile ?? document.store?.keys.sorted().first,
              let store = document.store?[name],
              let basal = store.basal
        else { return nil }

        let entries = basal.compactMap { entry -> BasalSchedule.Entry? in
            guard let rate = entry.value else { return nil }
            let offset = entry.timeAsSeconds ?? entry.time.flatMap(Self.secondsFromMidnight) ?? 0
            return BasalSchedule.Entry(startOffset: offset, ratePerHour: rate)
        }
        let timeZone = store.timezone.flatMap(Self.timeZone(named:)) ?? .current
        return BasalSchedule(entries: entries, timeZone: timeZone)
    }

    /// The time zone the looping phone keeps, as written in the site's profile; `nil` when the
    /// profile has none or it cannot be read.
    public static func timeZone(fromProfile data: Data, profileName: String? = nil) throws -> TimeZone? {
        let documents = try JSONDecoder().decode([ProfileDocument].self, from: data)
        guard let document = documents.first,
              let name = profileName ?? document.defaultProfile ?? document.store?.keys.sorted().first
        else { return nil }
        return document.store?[name]?.timezone.flatMap(Self.timeZone(named:))
    }

    /// Reads the time zone names uploaders write. Trio and AAPS use region names
    /// ("Europe/Stockholm"); Loop writes a fixed offset as "ETC/GMT-1", in capitals, which
    /// Foundation only accepts as "Etc/GMT-1". Plain offsets ("+01:00", "UTC+1") are accepted too.
    public static func timeZone(named name: String) -> TimeZone? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let exact = TimeZone(identifier: trimmed) { return exact }
        if let known = TimeZone.knownTimeZoneIdentifiers.first(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return TimeZone(identifier: known)
        }
        let upper = trimmed.uppercased()
        if upper.hasPrefix("ETC/"), let etc = TimeZone(identifier: "Etc/" + upper.dropFirst(4)) { return etc }

        // "+01:00", "-0700", "UTC+1", "GMT-3:30"
        var offset = Substring(upper)
        for prefix in ["UTC", "GMT"] where offset.hasPrefix(prefix) { offset = offset.dropFirst(prefix.count) }
        guard let sign = offset.first, sign == "+" || sign == "-" else { return nil }
        let digits = String(offset.dropFirst().filter(\.isNumber))
        guard !digits.isEmpty, digits.count <= 4 else { return nil }
        // One or two digits are hours; three or four end in two digits of minutes.
        let hourDigits = digits.count <= 2 ? digits : String(digits.dropLast(2))
        let minuteDigits = digits.count <= 2 ? "0" : String(digits.suffix(2))
        guard let hours = Int(hourDigits), let minutes = Int(minuteDigits), hours <= 14, minutes < 60 else { return nil }
        return TimeZone(secondsFromGMT: (sign == "-" ? -1 : 1) * (hours * 3600 + minutes * 60))
    }

    static func secondsFromMidnight(_ time: String) -> TimeInterval? {
        let parts = time.split(separator: ":").compactMap { Double($0) }
        guard parts.count >= 2 else { return nil }
        return parts[0] * 3600 + parts[1] * 60
    }

    // MARK: - Dates

    static func parseDate(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

// MARK: - Wire models

private struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

private extension KeyedDecodingContainer where Key == DynamicKey {
    /// Number, or a string holding a number.
    func double(_ key: String) -> Double? {
        let k = DynamicKey(key)
        if let value = try? decodeIfPresent(Double.self, forKey: k) { return value }
        if let string = try? decodeIfPresent(String.self, forKey: k) { return Double(string) }
        return nil
    }

    func string(_ key: String) -> String? {
        let k = DynamicKey(key)
        if let value = try? decodeIfPresent(String.self, forKey: k) { return value }
        if let number = try? decodeIfPresent(Double.self, forKey: k) { return String(number) }
        return nil
    }

    /// Bool, or "true"/"false", or 0/1.
    func bool(_ key: String) -> Bool? {
        let k = DynamicKey(key)
        if let value = try? decodeIfPresent(Bool.self, forKey: k) { return value }
        if let string = try? decodeIfPresent(String.self, forKey: k) { return Bool(string.lowercased()) }
        if let number = try? decodeIfPresent(Int.self, forKey: k) { return number != 0 }
        return nil
    }
}

private struct Entry: Decodable {
    let id: String?
    let type: String?
    let date: Double?
    let dateString: String?
    let sgv: Double?
    let mbg: Double?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        id = c.string("_id")
        type = c.string("type")
        date = c.double("date")
        dateString = c.string("dateString")
        sgv = c.double("sgv")
        mbg = c.double("mbg")
    }

    var resolvedDate: Date? {
        if let date { return Date(timeIntervalSince1970: date / 1000) }
        return dateString.flatMap(NightscoutParser.parseDate)
    }
}

private struct Treatment: Decodable {
    let id: String?
    /// Trio's own `id` field (distinct from Mongo's `_id`).
    let trioID: String?
    let fpuID: String?
    let eventType: String?
    let type: String?
    let createdAt: String?
    let timestamp: String?
    let mills: Double?
    let insulin: Double?
    let carbs: Double?
    let fat: Double?
    let protein: Double?
    let duration: Double?
    let durationInMilliseconds: Double?
    let absolute: Double?
    let rate: Double?
    let absorptionTime: Double?
    let automatic: Bool?
    let isSMB: Bool?
    let notes: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        id = c.string("_id")
        trioID = c.string("id")
        fpuID = c.string("fpuID")
        eventType = c.string("eventType")
        type = c.string("type")
        createdAt = c.string("created_at")
        timestamp = c.string("timestamp")
        mills = c.double("mills") ?? c.double("date")
        insulin = c.double("insulin")
        carbs = c.double("carbs")
        fat = c.double("fat")
        protein = c.double("protein")
        duration = c.double("duration")
        durationInMilliseconds = c.double("durationInMilliseconds")
        absolute = c.double("absolute")
        rate = c.double("rate")
        absorptionTime = c.double("absorptionTime")
        automatic = c.bool("automatic")
        isSMB = c.bool("isSMB")
        notes = c.string("notes")
    }

    var resolvedDate: Date? {
        if let createdAt, let date = NightscoutParser.parseDate(createdAt) { return date }
        if let timestamp {
            if let date = NightscoutParser.parseDate(timestamp) { return date }
            if let ms = Double(timestamp) { return Date(timeIntervalSince1970: ms / 1000) }
        }
        return mills.map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    var durationMinutes: Double? {
        duration ?? durationInMilliseconds.map { $0 / 60000 }
    }
}

private struct ProfileDocument: Decodable {
    struct Store: Decodable {
        let basal: [ScheduleEntry]?
        let timezone: String?
    }

    struct ScheduleEntry: Decodable {
        let time: String?
        let value: Double?
        let timeAsSeconds: Double?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: DynamicKey.self)
            time = c.string("time")
            value = c.double("value")
            timeAsSeconds = c.double("timeAsSeconds")
        }
    }

    let defaultProfile: String?
    let store: [String: Store]?
}
