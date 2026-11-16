# AIDReportKit for Kotlin

A Kotlin Multiplatform port of the `AIDReportKit` Swift target, for AndroidAPS and other Kotlin
apps. It computes the same report from the same data: both implementations are tested against
the shared cases in [`../Fixtures`](../Fixtures/README.md).

| Module | Contents | Swift counterpart |
| --- | --- | --- |
| `aidreport-core` | Models, `TherapyDataSource` and merging, basal timeline, validation and sanitizing, statistics, report definitions and presets, `ReportBuilder` / `AIDReport.generate`, JSON | `AIDReportKit` |

Targets: JVM (Android uses it), `iosArm64` and `iosSimulatorArm64`, the same as AndroidAPS. Built
with the versions AndroidAPS uses: Kotlin 2.4.21, kotlinx-serialization 1.12.0,
kotlinx-datetime 0.8.0, Gradle 9.8.2, JDK 21 (the JVM bytecode targets Java 17).

**Not ported yet:** the Nightscout reader (`AIDReportNightscout`), the Markdown and CSV text
output, the report pages, PDF and export sheet (`AIDReportUI`; on Android those would be Compose
and `PdfDocument`), and translations. Names and messages are in English for now.

## Building and testing

```sh
export JAVA_HOME=$(/usr/libexec/java_home -v 21)   # or the JDK 21 from Homebrew
./gradlew :aidreport-core:jvmTest                   # JVM: unit tests and the shared fixtures
./gradlew :aidreport-core:iosSimulatorArm64Test     # the unit tests on the iOS simulator target
./gradlew :aidreport-core:publishToMavenLocal       # io.github.codebymini:aidreport-core:0.1.0
```

## Using it

```kotlin
val source = object : TherapyDataSource {
    override val info = DataSourceInfo(HostApp.ANDROID_APS, displayUnit = GlucoseUnit.MMOLL, timeZone = TimeZone.currentSystemDefault())
    override suspend fun glucose(interval: DateInterval) = /* sensor readings in mg/dL */
    override suspend fun insulin(interval: DateInterval) = /* boluses, SMBs, temp basals, suspends: absolute units */
    override suspend fun carbs(interval: DateInterval) = /* carb entries */
}
val schedule = BasalSchedule(listOf(BasalSchedule.Entry(startOffset = 0.0, ratePerHour = 0.8)), timeZone)
val report = AIDReport.generate(
    ReportDefinition(range = ReportRange.month),
    source,
    ReportOptions(basalSchedule = schedule),
)
val json = JsonReportRenderer.render(report)   // the same JSON the Swift package writes and reads
```

To use it from an app before it is published, either publish it to the local Maven repository
(above) or include the build in the app's `settings.gradle.kts`:

```kotlin
includeBuild("../AIDReportKit/Kotlin")   // then depend on "io.github.codebymini:aidreport-core"
```

## Differences from the Swift API

The behavior is the same; the names follow Kotlin conventions:

| Swift | Kotlin |
| --- | --- |
| `Date`, `TimeInterval`, `TimeZone` | `kotlin.time.Instant`, seconds as `Double`, `kotlinx.datetime.TimeZone` |
| `async` functions, `glucose(in:)` | `suspend` functions, `glucose(interval)` |
| `.glucoseDistribution`, `.tempBasal` | `ReportSection.GLUCOSE_DISTRIBUTION`, `InsulinDose.Kind.TEMP_BASAL` (same names in JSON) |
| `sourceID` | `sourceId` (`sourceID` in JSON) |
| Failable `init?(values:)` | `Percentiles.of(values)`, `TimeInRanges.of(…)`, `GlycemiaRiskIndex.of(…)`; `BasalSchedule(…)` returns `null` for an empty schedule |
| `JSONReportRenderer`, `JSONFileReportPresetStore` | `JsonReportRenderer`; `ReportPresetCodec` turns presets into JSON for the app's own storage |
| `ReportRange.presets(within:)` | `ReportRange.presets(history)` |
| `dailyGlucoseHeatmap(calendar:)` | `dailyGlucoseHeatmap(firstWeekday)`, 1 = Sunday … 7 = Saturday |

Lists in a dataset are sorted by time when it is created, as in Swift. A dataset decoded from JSON
keeps the order it was written in, also as in Swift.
