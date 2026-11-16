# Shared report fixtures

The cases the Swift package and the Kotlin library must both reproduce. They keep the two
implementations giving the same numbers.

Each folder in `reports/` is one case:

| File | Contents |
| --- | --- |
| `input.json` | The dataset (glucose, insulin, carbs), the report definition, the report options (basal schedule, therapy settings, thresholds, AGP bucket size, metadata) and `now`, the moment the report is made |
| `report.json` | The report the Swift package builds from that input, as `JSONReportRenderer` writes it |

| Case | What it covers |
| --- | --- |
| `golden-utc` | The hand-computed two days from `Tests/AIDReportEndToEndTests/GoldenScenario.swift`: superseded and cancelled temp basals, a suspension, manual, automatic and external boluses, a fat/protein equivalent |
| `golden-stockholm-mmol` | The same data on a Stockholm clock (days of 23, 24 and 1 hours), mmol/L display, a basal schedule with three rates |
| `dirty-data` | Duplicates, an implausible reading, a future reading, negative and oversized amounts: the validation issues, and statistics that match the clean data |
| `late-install` | No data on the first day: no basal is invented before the first record |
| `mmol-delivered-as-mgdl` | mmol/L values passed as mg/dL: flagged as an error |
| `summer-time-week` | A synthetic week across the change to summer time in Stockholm, made five hours before the range ends, half-hour AGP buckets |
| `no-data` | An empty day |

## Running

```sh
xcrun swift test --filter SharedFixtureTests               # Swift, from the repository root
cd Kotlin && ./gradlew :aidreport-core:jvmTest              # Kotlin (JDK 21)
```

Both rebuild every case from `input.json` and compare the result with `report.json`. Numbers may
differ by a relative 1e-9, because the two languages add in different orders. Validation messages
are not compared, because Swift translates them; their codes, severities and times are.

The Kotlin tests also write the reports they build to `Kotlin/aidreport-core/build/fixture-output`.
When that folder exists, `SharedFixtureTests` decodes them in Swift and compares them with
`report.json` as well, so a report made on Android reads the same on iOS.

## Changing a calculation or adding a case

1. Change the Swift code and the Kotlin code together.
2. Regenerate the fixtures from Swift. The cases are defined in
   `Tests/AIDReportEndToEndTests/SharedFixtureTests.swift`:

   ```sh
   AIDREPORT_UPDATE_FIXTURES=1 xcrun swift test --filter SharedFixtureTests
   ```

3. Check the diff of `report.json`: only the numbers you meant to change should move.
4. Run the Kotlin tests. They fail until Kotlin computes the same numbers.
