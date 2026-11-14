# Integrating AIDReportKit

Each app gets an adapter that maps its own stored types onto `TherapyDataSource`. Adapters live
here, outside `Sources/`, because they compile inside the host app against that app's types
(LoopKit stores, Trio Core Data entities, LoopFollow's settings), and they reach those through
the app's own helpers rather than around them.

| App | Adapter | Reads | History | Basal schedule | Verified against |
| --- | --- | --- | --- | --- | --- |
| Loop | [`Loop/LoopTherapyDataSource.swift`](Loop/LoopTherapyDataSource.swift) | `GlucoseStore`, `DoseStore` (normalized doses), `CarbStore` | 7 days (`Bundle.main.localCacheDuration`), so the sheet offers D and W only | `BasalSchedule(_:)` from `LoopSettings.basalRateSchedule`: scheduled basal is only recorded between pump events | LoopKit/LoopWorkspace `dev` c50b6bb |
| Trio | [`Trio/TrioTherapyDataSource.swift`](Trio/TrioTherapyDataSource.swift), [`Trio/ReportExportSetup.swift`](Trio/ReportExportSetup.swift) | `GlucoseStored`, `PumpEventStored` (+ bolus/tempBasal), `CarbEntryStored` via `CoreDataStack.fetchEntitiesAsync` | 90 days | `BasalSchedule(trioProfile:)` from `Stat.Provider.basalProfile()` (today's profile; Trio keeps no profile history) | nightscout/Trio `dev` 3f6b238 |
| LoopFollow | [`LoopFollow/LoopFollowStats.swift`](LoopFollow/LoopFollowStats.swift) | Nightscout | Whatever the site holds | From the Nightscout profile | loopandlearn/LoopFollow `dev` 9f05be2 |

Any app can additionally use `NightscoutTherapyDataSource`, `HealthKitTherapyDataSource`, or a
`MergedTherapyDataSource` combining them with its own adapter.

## Current wiring in `workspaces/`

Each app is on its `feature/aid-stats` branch with the package linked by relative path and the
adapter compiled into the app target:

| App | Project change | Adapter location | Products linked to the app target |
| --- | --- | --- | --- |
| Loop | `Loop/Loop.xcodeproj` → local package `../../AIDReportKit` | `Loop/Loop/Managers/LoopTherapyDataSource.swift` | AIDReportKit, AIDReportUI |
| Trio | `Trio.xcodeproj` → local package `../AIDReportKit` | `Trio/Sources/Modules/Stat/TrioTherapyDataSource.swift`, `Trio/Sources/Modules/Stat/StatStateModel+Setup/ReportExportSetup.swift` | AIDReportKit, AIDReportUI |
| LoopFollow | `LoopFollow.xcodeproj` → local package `../AIDReportKit` | `LoopFollow/Stats/LoopFollowStats.swift` (synced folder, no file entry needed) | AIDReportKit, AIDReportNightscout, AIDReportUI |

The project edits were made with [`Scripts/wire-xcode-project.py`](../Scripts/wire-xcode-project.py),
which adds only the package reference, product dependencies, link phase entries and (for
non-synced folders) the adapter's file and build entries. To reapply it to a fresh clone:

```sh
Scripts/wire-xcode-project.py ../Trio/Trio.xcodeproj --target Trio --package-path ../AIDReportKit \
  --products AIDReportKit,AIDReportUI --source TrioTherapyDataSource.swift --group-sibling StatStateModel.swift
```

The `../` paths only work with the side-by-side `workspaces/` layout. Once AIDReportKit has a
remote, vendor it as a submodule like Trio's `RoundWhiteDiscKit` and change `relativePath` to
`AIDReportKit` (Trio, LoopFollow) or `../AIDReportKit` (Loop's project inside LoopWorkspace).

The copies inside the apps are the ones that compile; the files in this folder are the templates
they were made from. Keep the code in sync when changing an adapter. Trio and LoopFollow run
SwiftFormat as a build phase, which rewrites the copies to house style and replaces the file
header comment, so the essentials are repeated as doc comments on the adapter types.

All three apps build for the iOS 26.1 simulator with these changes (Xcode 26.1). LoopFollow
`dev` at 9f05be2 fails to build on its own: `BackgroundRefreshType.delayBoundedByHeartbeatInterval`
is missing the `.hub` case. Adding `.hub` to the `return false` branch fixes it; that fix is
upstream's to make and is not part of this branch.

## Export button

Each app opens the shared `ReportExportView` (AIDReportUI): segmented range, an "Include" list
of expanding categories with per-chart toggles, saved presets, then Export → patient name prompt → system share sheet. Presets are stored as JSON in the app's
Application Support folder.

| App | Where | Builds the report with |
| --- | --- | --- |
| Loop | Settings → Support → **Statistics Report** (once onboarding is complete) | `DeviceDataManager.makeStatisticsReport`: Loop's stores + basal schedule + settings header, read when the report is made |
| Trio | Statistics → share icon, top right (same spot as nightscout/Trio#1746) | `Stat.StateModel.makeAIDReport`: Core Data + basal profile + settings header |
| LoopFollow | Statistics → share icon next to Refresh (disabled without a Nightscout URL) | `LoopFollowStats.makeReport`: Nightscout + site basal profile, on the looper's clock |

## 1. Add the package

During development, with the apps checked out next to the package (`workspaces/`):

1. Open the app's workspace (`LoopWorkspace.xcworkspace`, `Trio.xcworkspace`, `LoopFollow.xcodeproj`).
2. **File → Add Package Dependencies… → Add Local…** and pick `../AIDReportKit`.
3. Link the products the app needs to its app target:
   - Loop: `AIDReportKit`, `AIDReportUI` (+ `AIDReportHealthKit` / `AIDReportNightscout` if wanted)
   - Trio: `AIDReportKit`, `AIDReportUI`
   - LoopFollow: `AIDReportKit`, `AIDReportNightscout`, `AIDReportUI`
   - Each app's test target: `AIDReportTesting`

Once the package has a remote, add it as a git submodule the way LoopWorkspace and Trio already
vendor their kits:

```sh
git submodule add <AIDReportKit remote URL> AIDReportKit
```

## 2. Add the adapter

Copy the app's adapter file(s) into the app target. Each file's header lists the wiring it
needs; the short version is:

```swift
let report = try await AIDReport.generate(definition, from: source, options: options)
let pdfURL = try PDFReportExporter.export(report)   // present in a share sheet
```

## 3. Check it

Add a conformance test to the app's test target so mapping mistakes (mmol/L delivered as mg/dL,
unclosed temp basals, double-fetched records) fail in CI rather than in a clinician's report:

```swift
let failures = try await AdapterConformance.check(source, interval: lastWeek)
XCTAssertEqual(failures, [])
```

## Notes per app

- **Localization**: the export sheet and PDF text come from the package's own String Catalogs
  (see the package README). Apps don't add those strings to their catalogs; translations ship with
  the package. Only the app-side entry points are the app's to localize: Loop's "Statistics Report"
  row, the "Export statistics report" accessibility label in Trio and LoopFollow, and LoopFollow's
  Nightscout-not-configured message. (Xcode adds those to the app catalog on build, together with
  unrelated catalog cleanup, so commit just those keys.)
- **Naming**: the carb model is `CarbIntake`, not `CarbEntry`, because LoopKit (used by Loop and
  Trio) already has a public `CarbEntry` protocol and files importing both would be ambiguous.
  No other public AIDReportKit type collides with LoopKit or with types defined in the three apps.
- **Loop**: the stores keep 7 days (`LOOP_LOCAL_CACHE_DURATION_DAYS`); anything older lives only
  in Apple Health. The sheet therefore gets `ReportRange.presets(within:)`, because a longer range
  would average 7 days of insulin and carbs over 30 or 90. `DoseEntry.netBasalUnits` is relative
  to the scheduled rate; the adapter uses `unitsInDeliverableIncrements`, the absolute units
  Loop's own `totalDelivery` sums. Header strings come from Loop (`AutomaticDosingStrategy.title`,
  `Bundle.main.bundleDisplayName`), so renamed builds and translations read right.
- **Trio**: pump history writes a new temp basal each loop cycle without closing the previous one;
  the adapter ends each where the next starts (`BasalTimeline.truncatingOverlaps`). Scheduled-basal
  rows are open-ended markers and are skipped with Trio's own `NSPredicate.notScheduledBasal`. A
  finalized temp basal carries the pump-reported total, already net of suspensions, so it is
  spread over its unsuspended time before the report clips suspended time (as `TDDSetup` does).
  A fat/protein-only meal is stored as a carb entry with 0 g and is not counted as a carb entry;
  FPU carb equivalents (`isFPU`) are tagged and kept out of carb totals. The CGM is named from
  `DeviceCatalog` and the dosing mode by `DosingMode.displayName`. The Statistics PDF export in
  nightscout/Trio#1746 can keep its own chart pages and use `ReportPage` / `PDFReportExporter`
  for the chrome, or switch to the built-in pages.
- **LoopFollow**: holds only `downloadDays` of data in memory, so reports read Nightscout, with
  the same requests LoopFollow itself makes (token as a query item, no cached responses, the
  profile in force now). The report keeps the looper's clock (see `reportTimeZone(profile:)`),
  so its days can differ from the Statistics screen, which keeps this device's. It also uses
  the consensus ranges rather than the screen's TIR/TITR/custom setting, and the sample standard
  deviation. Its existing `Stats/` TIR, AGP and GRI calculators can move onto AIDReportKit after
  a parity test on the same data.
