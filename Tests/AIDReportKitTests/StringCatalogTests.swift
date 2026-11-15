import AIDReportKit
import XCTest

/// Guards the String Catalogs that Loop, Trio and LoopFollow share, so translations imported from
/// Crowdin/Lokalise can't break formatting. Regenerate catalogs with Scripts/update-string-catalogs.sh.
final class StringCatalogTests: XCTestCase {
    private static let targets = ["AIDReportKit", "AIDReportUI", "AIDReportNightscout"]

    private struct Catalog {
        let target: String
        let sourceLanguage: String
        let strings: [String: [String: Any]]
    }

    private func catalogs() throws -> [Catalog] {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // AIDReportKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent()
        return try Self.targets.map { target in
            let url = packageRoot.appendingPathComponent("Sources/\(target)/Resources/Localizable.xcstrings")
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any], target)
            return Catalog(
                target: target,
                sourceLanguage: json["sourceLanguage"] as? String ?? "",
                strings: json["strings"] as? [String: [String: Any]] ?? [:]
            )
        }
    }

    /// Placeholder types in order of appearance, ignoring positional prefixes ("%1$@" → "@").
    private func placeholders(_ text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: "%(?:\\d+\\$)?(lld|ld|d|@|\\.\\d+f|f)")
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { String(text[Range($0.range(at: 1), in: text)!]) }.sorted()
    }

    func testCatalogsAreEnglishSourcedAndNotEmpty() throws {
        for catalog in try catalogs() {
            XCTAssertEqual(catalog.sourceLanguage, "en", catalog.target)
            XCTAssertFalse(catalog.strings.isEmpty, "\(catalog.target) catalog is empty")
        }
    }

    func testEveryKeyHasATranslatorComment() throws {
        for catalog in try catalogs() {
            for (key, entry) in catalog.strings {
                let comment = entry["comment"] as? String ?? ""
                XCTAssertFalse(comment.isEmpty, "\(catalog.target): \"\(key)\" has no comment")
            }
        }
    }

    func testNoStaleKeys() throws {
        for catalog in try catalogs() {
            let stale = catalog.strings.filter { ($0.value["extractionState"] as? String) == "stale" }.keys.sorted()
            XCTAssertEqual(stale, [], "\(catalog.target): run Scripts/update-string-catalogs.sh")
        }
    }

    func testTranslationsKeepPlaceholders() throws {
        for catalog in try catalogs() {
            for (key, entry) in catalog.strings {
                let expected = placeholders(key)
                let localizations = entry["localizations"] as? [String: Any] ?? [:]
                for (language, value) in localizations {
                    guard let unit = (value as? [String: Any])?["stringUnit"] as? [String: Any],
                          let translated = unit["value"] as? String else { continue } // plural variations are checked by Xcode
                    XCTAssertEqual(placeholders(translated), expected,
                                   "\(catalog.target) [\(language)] \"\(key)\" → \"\(translated)\"")
                }
            }
        }
    }

    func testEnglishFallbackMatchesSourceStrings() {
        XCTAssertEqual(ReportRange.lastDays(14).displayName, "Last 14 days")
        XCTAssertEqual(ReportRange.day.displayName, "Last 24 hours")
        XCTAssertEqual(ReportSection.glycemiaRiskIndex.title, "Glycemia Risk Index")
        XCTAssertEqual(ReportSection.Category.carbs.title, "Carbs")
        XCTAssertEqual(ReportSection.glucoseDistribution.menuTitle, "Distribution")
        XCTAssertEqual(DayPeriodRanges.Period.afternoon.title, "Afternoon")
        let f = ReportFormatter(unit: .mgdL, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(f.duration(5400), "1 h 30 min")
        XCTAssertEqual(f.bandLabels(.consensus).inRange, "In range (70–180)")
    }
}
