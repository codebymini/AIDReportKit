# AIDReportKit

A Swift package that aggregates, validates, tests and reports glucose, insulin and carb
statistics for open-source automated insulin delivery apps: **Loop**, **Trio** and **LoopFollow**.
It reads from each app's own store, from **Nightscout**, or from **Apple Health**, and produces the
same numbers and the same report everywhere.

The same repository holds a Kotlin Multiplatform port of the core for **AndroidAPS** and other
Kotlin apps ([`Kotlin/`](Kotlin/README.md)). Both implementations are tested against one set of
fixtures ([`Fixtures/`](Fixtures/README.md)), so a report gives the same numbers on either platform.

```
            ┌──────────── TherapyDataSource ────────────┐
 Loop stores │  Trio Core Data │ LoopFollow │ Nightscout │ Apple Health │ Merged(…)
            └──────────────────────┬────────────────────┘
                                   ▼
                      TherapyDataset (mg/dL, absolute units)
                                   │
         DatasetValidator ─────────┤  issues on the raw data (errors / warnings / notes)
                                   ▼
         DatasetSanitizer          dedupe, drop implausible, end superseded temp basals,
                                   fill basal gaps from the schedule
                                   ▼
         StatsAggregator           summary · per day · time of day (AGP)
                                   ▼
         TherapyReport ──► Markdown · JSON · CSV · multi-page PDF
```

## Products

| Product | What it contains | Depends on |
| --- | --- | --- |
| `AIDReportKit` | Models, `TherapyDataSource`, merging, basal timeline, statistics, validation, report definitions/presets, Markdown/JSON/CSV | Foundation only |
| `AIDReportNightscout` | Nightscout v1 entries/treatments/profile parser and HTTP source | AIDReportKit |
| `AIDReportHealthKit` | Apple Health source (blood glucose, insulin delivery, carbohydrates) | AIDReportKit, HealthKit |
| `AIDReportUI` | A4/Letter multi-page PDF, one page per section, and `ReportExportView`, the report builder sheet the apps present (SwiftUI + Charts, iOS 16+) | AIDReportKit |
| `AIDReportTesting` | Deterministic synthetic data, in-memory source, adapter conformance checks | AIDReportKit |

The package never imports LoopKit, Trio's Core Data model or LoopFollow types. Each app adds a
small adapter from [`Integrations/`](Integrations/README.md) to its own target.

### Kotlin

| Module | What it contains | Swift counterpart |
| --- | --- | --- |
| `Kotlin/aidreport-core` | Models, data sources and merging, basal timeline, validation, statistics, report definitions/presets, report builder, JSON. JVM (Android), iOS arm64 and simulator | `AIDReportKit` |

The Nightscout reader, the text exports and the pages/PDF are not ported yet. The Kotlin report
JSON has the same shape as Swift's (`TherapyReport.schemaVersion` 2): each side reads the reports
the other writes. See [`Kotlin/README.md`](Kotlin/README.md) for building it, using it from an app and
how its names differ from Swift's.

## Quick start

```swift
import AIDReportKit
import AIDReportNightscout
import AIDReportHealthKit

let nightscout = NightscoutTherapyDataSource(
    configuration: NightscoutConfiguration(baseURL: siteURL, token: token)
)
let health = HealthKitTherapyDataSource()
try await health.requestAuthorization()

// Glucose fills gaps across sources; insulin and carbs come whole from the first
// source that has data, so nothing mirrored between Nightscout and Health counts twice.
let source = MergedTherapyDataSource([nightscout, health])

let definition = ReportDefinition(
    name: "Endo visit",
    range: .threeMonths,
    sections: [.overview, .glucoseDistribution, .glycemiaRiskIndex,
               .insulinTotalDailyDose, .carbsTotals, .dataQuality]
)
let profile = try await nightscout.profile()
let options = ReportOptions(basalSchedule: profile.basalSchedule, therapySettings: profile.therapySettings)
let report = try await AIDReport.generate(definition, from: source, options: options)

let markdown = MarkdownReportRenderer().render(report)
let json = try JSONReportRenderer().render(report)
let csv = CSVExporter().daily(report)
let pdfURL = try PDFReportExporter.export(report)   // import AIDReportUI
```

## Report builder

The report model follows the concepts in the Trio statistics export
([nightscout/Trio#1746](https://github.com/nightscout/Trio/pull/1746)), made app-neutral:

- **`ReportSection`**: one flat catalogue of everything a report can contain: overview (with a
  small AGP), glucose distribution, GRI, percentiles/distribution by day, a calendar heatmap of each day's
  average glucose, carbs, insulin (with basal rates, carb ratios and ISF), the other therapy
  settings, bolus distribution, data quality. Case order is the PDF page order: overview, the charts in export
  menu order (glucose, carbs, insulin), data quality last. Each has a category, a short
  `menuTitle` and a minimum span (by-day sections need ≥ 2 days).
- **`ReportDefinition`**: name (for the preset; not printed) + `ReportRange` (a rolling window ending now, or custom) +
  ordered sections. Renderers emit one section/page per entry, in order.
- **`ReportPreset` / `ReportPresetStore`**: saved definitions for recurring reports. Back the store
  with the host's own storage, or use `JSONFileReportPresetStore`.
- **`ReportMetadata`**: optional patient name, hardware (CGM, pump, device), software (app,
  version, build date) and key settings (closed loop, SMB, dynamic ISF…) so a printed report
  stands on its own.
- **`ReportExportView`**: the export sheet, laid out like the Trio export menu
  ([nightscout/Trio#1777](https://github.com/nightscout/Trio/pull/1777)): a segmented range
  (D / W / M / 3 M, month by default), an "Include" list where every category (Summary, Glucose,
  Carbs, Insulin) is a row that expands to per-chart toggles named as in Trio, "Save as Preset…", and an Export button that asks for the patient name (remembered
  on the device, prefilled next time) before building the PDF. Per-day charts are disabled for
  the one-day range and come back when the range is lengthened. Hosts can pass their own sheet
  background (`background:`), as Trio does with its gradient, and the ranges they can honour
  (`ranges:`): Loop's stores keep 7 days, so it passes `ReportRange.presets(within:)` and offers
  D and W only, rather than averaging a week of data over a month.
- **`PDFReportExporter`**: one page per section with shared header/footer, always light appearance.
  Hosts can pass their own SwiftUI pages wrapped in `ReportPage`. See
  [`Docs/sample-report.pdf`](Docs/sample-report.pdf) (the six default pages, synthetic data; the by-day pages and Bolus Distribution are optional).

## Statistics

All glucose values are mg/dL internally; `GlucoseUnit` converts only for display.

| Metric | Definition |
| --- | --- |
| Time in ranges | Share of sensor readings: very low < 54, low 54–< 70, in range 70–180, high > 180–250, very high > 250 mg/dL; tight range 70–140 (2019 international consensus; thresholds configurable) |
| Mean, SD, CV | Sample SD (n − 1); CV = SD / mean (target ≤ 36%) |
| GMI | 3.31 + 0.02392 × mean mg/dL |
| eA1c | (mean mg/dL + 46.7) / 28.7 (ADAG), and in mmol/mol 10.929 × (eA1c − 2.152), as Trio and LoopFollow show it next to GMI |
| GRI | 3.0 × (VLow + 0.8 × Low) + 1.6 × (VHigh + 0.5 × High), capped at 100, zones A–E. Always uses the fixed consensus thresholds |
| CGM coverage | Share of 5-minute slots with ≥ 1 reading (correct for 1- and 5-minute sensors) |
| AGP | 5/25/50/75/95 percentiles by time of day (default 60-minute buckets) in the data's time zone, drawn small on the overview |
| Ranges by time of day | Time in ranges at night (00–06), in the morning (06–12), afternoon (12–18) and evening (18–24), all days overlaid, on the report's clock (`TherapyReport.dayPeriods`, the same parts of the day as LoopFollow). Drawn as four stacked bars on the Glucose Distribution page |
| GRI grid | Hypoglycemia component across, hyperglycemia component up; zones A–E are the triangles under 3 × hypo + 1.6 × hyper = 20, 40, 60, 80, 100, as in Trio and LoopFollow. The dot is the report |
| Time zone | Days, times of day, midnight and every printed time are on the clock of `DataSourceInfo.timeZone`, never implicitly the device's. Loop and Trio run on the looper's phone, so that is the device time zone. A follower passes the looper's: `NightscoutTherapyDataSource.profile()` returns the time zone in the site's profile (Trio/AAPS region names, Loop's `ETC/GMT-1`, plain offsets) and `usingTimeZone(_:)` applies it. The header prints it, e.g. `Generated 2026-11-14 23:33 (GMT+1)` |
| Partial days | A rolling range starts and ends mid-day. When the first or the last data point is more than 10 minutes from midnight (on the report's clock), every page with per-day values and the Data Quality page carry a warning naming the short day(s) (`TherapyReport.partialDayWarning`, `DataSpan`) |
| Daily heatmap | One calendar cell per day, colored by where that day's mean glucose falls against the thresholds (consensus cut-offs by default): green in range (70–180), yellow high (> 180–250), red very high (> 250), dark red for a day averaging below 70. The band is decided on the average as printed (whole mg/dL, or mmol/L to one decimal), so a cell reading "180" or "10.0" is always green, and the value is printed in every cell, so the page never relies on color alone. Days under 50% CGM coverage are marked `*`; days without data are grey |
| Insulin | Total, basal (scheduled + temp), bolus split manual / automatic (SMB) / external, average daily dose, basal share, suspended time, basal record coverage |
| Programmed vs delivered basal | Programmed basal is what the basal schedule passed in `ReportOptions.basalSchedule` would have delivered, counted from the first to the last data point like delivered basal, so a period that starts before the data is not read as a shortfall. Delivered basal is what was actually given: scheduled and temp basal, net of suspensions. Without a schedule, programmed basal is left out. The schedule is the current one: none of the apps keep a history of profile changes |
| Therapy settings | `TherapySettingsSnapshot` (passed as `ReportOptions.therapySettings`): carb ratios, ISF and glucose targets by time of day in mg/dL, plus groups of other settings the app formats in its own words. The basal schedule is shown with them. The Insulin page prints basal rates, carb ratios and ISF; the optional Settings page prints targets and the groups. They are the settings in force when the report is made: none of the apps keep a history of changes. Loop maps LoopKit's `TherapySettings`, Trio its stored settings files and preferences, LoopFollow the followed site's Nightscout profile |
| Overview | The first page: time in range (with time below and above), GRI, CV / SD and eA1c, a thin time-in-range bar and a small AGP, then total daily dose, programmed basal and delivered basal per day (delivered as a share of programmed). Every renderer takes the numbers from `TherapyReport.overviewMetrics(_:)`. Page-by-page contents: [`Docs/report-pages.md`](Docs/report-pages.md) |
| Reported figures | Reports show insulin and carbs as per-day averages (dose, basal, bolus, automatic bolus, boluses, carb grams, carb entries, suspended time), never period totals, so a week and three months read the same way. The totals stay available on `InsulinStatistics` / `CarbStatistics` and in the JSON export |
| Carbs | Total, entries, average per entry and per day, fat/protein; Trio FPU carb equivalents reported separately and excluded from totals. Only entries with carbs count as carb entries: a fat/protein-only meal (0 g) adds its fat and protein but not to the entry count |
| Nightscout | Read the way LoopFollow reads it: token as a query item, responses never from cache, the profile in force now (`profiles.json` filtered on `startDate`, falling back to the newest record). Pump suspensions are taken from Loop's "Suspend Pump" / "Resume Pump" treatments and from Trio's "PumpSuspend" / "PumpResume" notes; one whose resume never reached the site ends at the next temp basal |
| Units | mg/dL inside the package; mmol/L by HealthKit's factor (18.015588, as in Loop and LoopKit) |

## Validation

`DatasetValidator` runs on the **raw** data so adapter and data problems are reported, not hidden.
Issues carry a stable `ValidationCode`, severity and timestamp; the report keeps them alongside the
statistics. Add host-specific rules by conforming to `ValidationRule`.

| Code | Severity | Meaning |
| --- | --- | --- |
| `glucose.likelyMmolL` | error | Median below 30: mmol/L values delivered as mg/dL |
| `glucose.implausibleValue` | error | Outside 20–600 mg/dL |
| `glucose.duplicate` | warning | Same sourceID, or same value < 30 s apart |
| `glucose.rateOfChange` | warning | > 6 mg/dL/min between consecutive readings |
| `glucose.gap` / `glucose.lowCoverage` | info / warning | Sensor gaps > 15 min; coverage < 70% |
| `insulin.negative` / `insulin.endBeforeStart` | error | Malformed doses |
| `insulin.bolusAboveMax` / `insulin.basalRateAboveMax` | warning | > 25 U bolus, > 10 U/h basal |
| `insulin.basalOverlap` | warning | Temp basals not ended when superseded |
| `insulin.lowBasalCoverage` | warning | Basal records cover < 90%: provide a `BasalSchedule` |
| `carbs.negative` / `carbs.aboveMax` / `carbs.duplicate` | error / warning | |
| `dataset.futureTimestamp` | error | Clock or time-zone problem |
| `dataset.shortSpan` | info | Under 14 days |

All limits live in `ValidationConfiguration`.

## Testing

```sh
swift test                                              # 116 tests, macOS
AIDREPORT_PDF_OUTPUT=/tmp/sample.pdf swift test --filter PDF   # also writes a sample PDF
cd Kotlin && ./gradlew :aidreport-core:jvmTest          # the Kotlin port (JDK 21)
```

**Shared fixtures.** `Fixtures/reports` holds seven cases (input data and the report Swift builds
from it): the golden scenario on a UTC and a Stockholm clock, dirty data, a late install, mmol/L
passed as mg/dL, a week across the change to summer time and an empty day. `SharedFixtureTests`
(Swift) and `SharedFixtureTest` (Kotlin) rebuild every case and compare the whole report JSON, so a
calculation changed on one side only fails the other side's tests. Swift also decodes the reports
the Kotlin tests write (`Kotlin/aidreport-core/build/fixture-output`) and checks they say the same. See
[`Fixtures/README.md`](Fixtures/README.md) for regenerating them.

`Tests/AIDReportEndToEndTests` runs one hand-computed two-day scenario (`GoldenScenario.swift`,
every expected number is derived in comments) through the whole pipeline: pump-history,
Nightscout (paged fake server), Apple Health and merged sources must all produce the same
statistics, dirty input must not change them, and the Markdown, CSV, JSON and PDF output must
show them. Change a calculation and these tests tell you which reader-visible number moved.

Host apps can use `AIDReportTesting` in their own test targets:

```swift
import AIDReportTesting

func testTrioAdapterConformance() async throws {
    let failures = try await AdapterConformance.check(TrioTherapyDataSource(context: testContext, displayUnit: .mgdL),
                                                      interval: lastWeek)
    XCTAssertEqual(failures, [])
}
```

`SyntheticTherapyGenerator(seed:days:)` produces a deterministic, realistic dataset (CGM with daily
rhythm and meal excursions, meal boluses, 30-minute loop temp basals, SMBs) that validates cleanly.

## Localization

Every user-facing string (export sheet, PDF pages, section and range names, validation messages,
Markdown report) comes from a String Catalog inside the package, so one translation serves Loop,
Trio and LoopFollow:

| Target | Catalog | Keys |
| --- | --- | --- |
| `AIDReportKit` | `Sources/AIDReportKit/Resources/Localizable.xcstrings` | 131 |
| `AIDReportUI` | `Sources/AIDReportUI/Resources/Localizable.xcstrings` | 92 |
| `AIDReportNightscout` | `Sources/AIDReportNightscout/Resources/Localizable.xcstrings` | 2 |

- **Adding a string**: `String(localized: "…", bundle: .module, comment: "context for translators")`.
  Always pass `bundle: .module` (SwiftUI `Text("…")` literals would look in the *app's* catalog) and a
  comment. Chart plot labels go through `plotLabel(_:)` so they stay out of the catalog.
- **Updating catalogs**: `Scripts/update-string-catalogs.sh` compiles the package with string extraction
  and merges the keys into each catalog (`xcstringstool sync`), keeping existing translations.
- **Translating**: import the `.xcstrings` files into Crowdin (Trio) or Lokalise (Loop) like the apps'
  own catalogs, or edit them in Xcode. `StringCatalogTests` fails if a key lacks a comment, a key is
  stale, or a translation changes the placeholders (`%@`, `%lld`).
- **At runtime**: Xcode compiles the catalogs into each package resource bundle when building the app;
  hosts need no setup. Command-line `swift build` only copies the catalog, so `swift test` runs in English.
- **Not yet localized**: numbers and dates use fixed formats (`yyyy-MM-dd`, `6.8%`); CSV and JSON
  exports are machine-readable and stay English by design.

## Adding to Loop, Trio and LoopFollow

See [`Integrations/README.md`](Integrations/README.md) for the per-app adapters and wiring.

## Requirements

Swift 5.9+, iOS 15 (PDF: iOS 16), macOS 13, watchOS 8 (no PDF).
