# What's on each report page

The PDF has one page per section, in this order. The export sheet preselects the pages marked
**default**; the by-day pages are opt-in and need at least two days. There is no separate AGP page; a small AGP sits on the overview. Glucose is shown in the
user's unit (mg/dL or mmol/L). Insulin and carbs are per-day averages, never period totals.
Examples below are from 14 days of synthetic data. [`sample-report.pdf`](sample-report.pdf) has the six default pages; the optional ones are described from the same data with every page switched on.

## On every page

- **Header:**
  - "Glucose Report", and the patient name if one was entered. The app is named under Software, and a preset's name is not printed.
  - Category · range, e.g. "Glucose · Last 14 days (2026-01-01 00:00 – 2026-01-15 00:00)".
  - "Generated *date time (GMT+x)* · Source · Units".
  - Three columns:
    - **Hardware:** CGM, pump, device.
    - **Software:** app, version, build date.
    - **Settings:** whatever the app passes (Trio: dosing mode, SMB, UAM, Dynamic ISF; Loop: closed loop, dosing strategy).
- **Footer:** "Not a medical device. Discuss therapy changes with your care team." and "Page *n* of *N*".
- **Partial-day warning:** shown on the pages with per-day values and on Data Quality, when the first or last data point is more than 10 minutes from midnight. Example: "The first day is partial: data starts at …, so that day shows less than a full day."
- **No sensor data:** glucose pages show "No sensor glucose in this period." instead of charts.

## 1. Overview (default)

Small numbers (14 pt values, 8.5 pt labels, fixed sizes so it reads the same rendered on an iPhone
as on a Mac), in four columns.

**Glucose**

| Tile | Value | Line under it |
| --- | --- | --- |
| Time in range | 72.5% | Below 0.0% · above 27.5% |
| GRI | 22.0 | Zone B |
| CV / SD | 24.7% / 38 mg/dL | |
| eA1c | 7.0% | 53 mmol/mol |

- **Time in range bar:** one thin horizontal bar, very low → very high. Under it, each range with its cut-offs and share, e.g. "In range (70–180) 72.5%".
- **Mini AGP:** median with 25–75% and 5–95% bands by time of day, plus the low and high threshold lines. The caption names the bands, so there is no legend. There is no separate AGP page.

**Insulin**

| Tile | Value | Line under it |
| --- | --- | --- |
| Total daily dose | 39.5 U | |
| Programmed basal per day | 19.2 U | Basal schedule, or "No basal schedule" with value "–" |
| Delivered basal per day | 19.0 U | 99% of programmed |

## 2. Glucose Distribution (default)

- **Stacked time-in-range bar** with a label for each band:
  - Very high (>250)
  - High (>180–250)
  - In range (70–180)
  - Low (54–<70)
  - Very low (<54)
  - Tight range (70–140), listed under the bar.
- **Next to the bar:** mean, median, standard deviation, coefficient of variation, GMI, lowest / highest.
- **"By time of day":** one full-height stacked bar each for night (00–06), morning (06–12), afternoon (12–18) and evening (18–24), all days overlaid, as wide as the bar above. All four keep their place even when one has no readings. Each range's share is printed inside its segment when it is at least 6%; the legend names the ranges. These are the same parts of the day as LoopFollow's statistics.

## 3. Glycemia Risk Index (default)

- **Header line:** "GRI 22.0 / 100", "Zone B".
- **Chart:** the zone triangles A–E, with the hypoglycemia component on the x axis and the hyperglycemia component on the y axis. A dot marks this period.
- **Numbers:**
  - Very low and low with the hypoglycemia component.
  - High and very high with the hyperglycemia component.
  - All against fixed thresholds in mg/dL.
- **Worked sum:**
  - "Weighted hypoglycemia: 3 × 0.0 = 0.0"
  - "Weighted hyperglycemia: 1.6 × 13.8 = 22.0"
  - "Combined: 22.0, capped at 100."
- **Explanation:** what GRI is, that it uses fixed thresholds, and that short periods or sensor gaps make it less representative.

## 4. Glucose Percentiles by Day (by day)

- **Chart:** one box per day.
  - Whisker 5–95%, box 25–75%, dot at the median.
  - Threshold lines.
  - Days labelled on the looper's clock.
- **Caption:** "Per day: whisker 5–95%, box 25–75%, dot median (mg/dL)."
- **No numbers on the page.**

## 5. Glucose Distribution by Day (by day)

- **Chart:** one 100% stacked bar per day: very low, low, in range, high, very high.
- **No numbers or caption on the page.**

## 6. Average Glucose by Day (by day)

- **Numbers:**
  - Days with data, e.g. "14 of 14".
  - Lowest daily average, with its date.
  - Highest daily average, with its date.
- **Calendar:**
  - One row per week, weekdays starting on the user's first weekday.
  - Each cell holds the date and that day's average glucose, colored by consensus band: green in range, yellow high, red very high, dark red low, grey no data.
  - Week labels on the left.
- **Legend:** each band with how many days fell in it. "Low" only appears when a day was low.
- **Caption:** explains the colors and counts.
- **Low coverage:** days under 50% CGM coverage are marked `*`, with the note "Under 50% CGM coverage that day."

## 7. Carbohydrates (default)

- **Numbers:**
  - Average per day.
  - Carb entries per day.
  - Average per entry.
  - Largest entry.
  - Fat / protein per day, only when any was logged.
  - Fat/protein carb equivalents per day (Trio FPU), only when there are any.
- **Chart:** carbs per day.
- **Not counted as carb entries:** fat/protein-only meals.

## 8. Insulin (default)

- **Numbers** (named as on the Overview):
  - Total daily dose.
  - Delivered basal per day.
  - Programmed basal per day ("–" without a basal schedule).
  - Bolus per day.
  - Basal share.
  - Suspended per day.
- **Chart:** stacked basal + bolus per day (shorter when settings follow).
- **Settings**, when the app supplies them, each as one horizontal bar across the day, split where the value changes:
  - Basal rates (U/h, blue), with the range and what the schedule delivers in a day, e.g. "0.70–0.90 · 19.2 U per day".
  - Carb ratios (g/U, orange), with the range.
  - Insulin sensitivity (mg/dL or mmol/L per U, purple), with the range.
  - Each part is shaded by its value (darker is higher) and carries the value when it is wide enough; the range covers parts too narrow for a label.
  - A shared hour axis (00:00–24:00 every three hours) under the bars.
  - "Settings in force when the report was made. Changes during the period are not shown."

## 9. Settings (opt-in)

Everything the Insulin page does not show:

- **Glucose targets** by time of day (one value, or low–high).
- **The app's other settings in groups**, two groups to a row, under the app's own names:
  - **Loop:** Delivery Limits; Glucose Settings (safety limit, pre-meal and workout ranges); Insulin Model; Dosing.
  - **Trio:** Limits; Insulin Model; SMB; Algorithm (dosing mode, UAM, Dynamic ISF, adjustment factor, autosens).
  - **LoopFollow:** whatever the followed site's Nightscout profile holds (insulin action time).
- **Nothing supplied:** "The app supplied no other settings."

## 10. Bolus Distribution (opt-in)

- **Numbers:**
  - Manual bolus per day.
  - Automatic bolus per day.
  - External bolus per day.
  - Boluses per day.
  - Automatic boluses per day.
- **Chart:** stacked manual / automatic (SMB) / external per day.

## 11. Data Quality (default)

- **Numbers:**
  - CGM coverage.
  - Basal record coverage.
  - Errors, warnings and notes from validation (counts only).
- **"No issues found."** when validation found nothing. The individual issues are not listed (removed on purpose).

## Markdown / text export

Same sections in the same order, as tables instead of charts. By-day sections become per-day
tables, and the heatmap becomes one table with a row per week.

## Things to look at in review

These are my notes from putting this list together, not decisions:

- **Repeats of the overview:** CV and SD appear on both the Overview and Glucose Distribution.
- **Carbs page title:** the page is "Carbohydrates", but the export sheet calls it "Total Meals" (Trio's name).
- **External bolus:** "External bolus per day" shows 0.0 U even when there are no external boluses.
- **Pages with only a chart:** Percentiles by Day and Distribution by Day have no numbers.
- **Data Quality:** says how many problems there are, not which ones.
