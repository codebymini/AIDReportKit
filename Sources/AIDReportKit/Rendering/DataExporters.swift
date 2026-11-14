import Foundation

/// The full report as JSON (ISO 8601 dates, sorted keys) — for sharing, archiving or
/// feeding other tools. `TherapyReport.schemaVersion` versions the format.
public struct JSONReportRenderer: Sendable {
    public init() {}

    public func render(_ report: TherapyReport) throws -> Data {
        try Self.encoder.encode(report)
    }

    public func decode(_ data: Data) throws -> TherapyReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return try decoder.decode(TherapyReport.self, from: data)
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return encoder
    }
}

/// CSV exports for spreadsheets. Glucose columns are mg/dL so files are comparable across users.
public struct CSVExporter: Sendable {
    public init() {}

    /// One row per day.
    public func daily(_ report: TherapyReport) -> String {
        let f = ReportFormatter(report: report)
        let header = [
            "date", "readings", "mean_mgdl", "sd_mgdl", "cv_pct", "gmi_pct",
            "very_low_pct", "low_pct", "in_range_pct", "high_pct", "very_high_pct", "coverage_pct",
            "tdd_u", "basal_u", "bolus_u", "automatic_bolus_u", "carbs_g", "carb_entries",
        ]
        let rows = report.daily.map { day -> [String] in
            let g = day.glucose
            let t = g?.timeInRanges
            return [
                f.day(day.day),
                g.map { "\($0.readingCount)" } ?? "0",
                num(g?.mean), num(g?.standardDeviation), num(g.map { $0.coefficientOfVariation * 100 }), num(g?.gmi),
                num(t.map { $0.veryLow * 100 }), num(t.map { $0.low * 100 }), num(t.map { $0.inRange * 100 }),
                num(t.map { $0.high * 100 }), num(t.map { $0.veryHigh * 100 }), num(g.map { $0.coverage * 100 }),
                num(day.insulin.totalUnits, 2), num(day.insulin.basalUnits, 2), num(day.insulin.bolusUnits, 2),
                num(day.insulin.automaticBolusUnits, 2), num(day.carbs.totalGrams, 0), "\(day.carbs.entryCount)",
            ]
        }
        return csv(header, rows)
    }

    /// Raw readings, for checking a report against the source data.
    public func glucose(_ readings: [GlucoseReading], timeZone: TimeZone = .current) -> String {
        let f = ReportFormatter(unit: .mgdL, timeZone: timeZone)
        return csv(["date", "mgdl", "kind", "source_id"], readings.map {
            [f.dateTime($0.date), num($0.mgdL, 0), $0.kind.rawValue, $0.sourceID ?? ""]
        })
    }

    private func num(_ value: Double?, _ decimals: Int = 1) -> String {
        value.map { String(format: "%.\(decimals)f", $0) } ?? ""
    }

    private func csv(_ header: [String], _ rows: [[String]]) -> String {
        ([header] + rows).map { $0.map(escape).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    private func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
