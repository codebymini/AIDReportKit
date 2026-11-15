import Foundation

/// Renders a report as Markdown, one `##` section per `ReportSection`, in the definition's order.
/// Text comes from the package's String Catalog, so the output follows the user's language.
public struct MarkdownReportRenderer: Sendable {
    public var maximumListedIssues: Int

    /// Every issue is listed by default; pass a limit to cut the list short.
    public init(maximumListedIssues: Int = .max) {
        self.maximumListedIssues = maximumListedIssues
    }

    public func render(_ report: TherapyReport) -> String {
        let f = ReportFormatter(report: report)
        let source = report.source.name + (report.source.appVersion.map { " \($0)" } ?? "")
        var lines = ["# \(report.title)", ""]
        if let patientName = report.metadata.printablePatientName {
            lines.append(String(localized: "- **Patient:** \(patientName)", bundle: .module, comment: "Markdown report header line; the argument is the patient's name"))
        }
        lines.append(String(localized: "- **Period:** \(f.period(report.interval)) (\(report.definition.range.displayName))", bundle: .module,
                            comment: "Markdown report header line; arguments are a date range and the range name"))
        lines.append(String(localized: "- **Source:** \(source)", bundle: .module, comment: "Markdown report header line; the argument is the data source"))
        lines.append(String(localized: "- **Generated:** \(f.dateTimeWithZone(report.generatedAt))", bundle: .module, comment: "Markdown report header line; the argument is a date and time"))
        lines.append(String(localized: "- **Glucose unit:** \(report.displayUnit.rawValue)", bundle: .module, comment: "Markdown report header line; the argument is mg/dL or mmol/L"))
        for item in report.metadata.hardwareItems + report.metadata.softwareItems + report.metadata.settings {
            lines.append("- **\(item.label):** \(item.value)")
        }

        for section in report.renderableSections {
            lines += ["", "## \(section.title)", ""]
            if let warning = report.partialDayWarning(for: section) {
                lines += [String(localized: "**Warning:** \(warning)", bundle: .module, comment: "Markdown warning line; the argument is the warning sentence"), ""]
            }
            lines += body(section, report, f)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func body(_ section: ReportSection, _ report: TherapyReport, _ f: ReportFormatter) -> [String] {
        switch section {
        case .overview: return overview(report, f)
        case .glucoseDistribution: return glucoseDistribution(report, f)
        case .glucoseDistributionByDay: return distributionByDay(report, f)
        case .glucosePercentileByDay: return percentilesByDay(report, f)
        case .glucoseHeatmapByDay: return heatmapByDay(report, f)
        case .glycemiaRiskIndex: return gri(report, f)
        case .insulinTotalDailyDose: return totalDailyDose(report, f)
        case .therapySettings: return therapySettings(report, f)
        case .insulinBolusDistribution: return bolusDistribution(report, f)
        case .carbsTotals: return carbs(report, f)
        case .dataQuality: return dataQuality(report, f)
        }
    }

    // MARK: - Shared labels

    private var metricHeader: [String] {
        [String(localized: "Metric", bundle: .module, comment: "Table column header"),
         String(localized: "Value", bundle: .module, comment: "Table column header")]
    }

    private var dayHeader: String { String(localized: "Day", bundle: .module, comment: "Table column header: calendar day") }
    private var medianLabel: String { String(localized: "Median", bundle: .module, comment: "Statistic: median value") }
    private var noSensorGlucose: String {
        String(localized: "No sensor glucose in this period.", bundle: .module, comment: "Shown instead of glucose statistics when there is no CGM data")
    }

    // MARK: - Sections

    private func overview(_ report: TherapyReport, _ f: ReportFormatter) -> [String] {
        let metrics = report.overviewMetrics(f)
        var rows = (metrics.glucose + metrics.insulin).map { metric in
            [metric.label, metric.detail.map { "\(metric.value) (\($0))" } ?? metric.value]
        }
        if metrics.glucose.isEmpty {
            rows.insert([String(localized: "Glucose", bundle: .module, comment: "Report category heading"),
                         String(localized: "No sensor data", bundle: .module, comment: "Shown when there are no CGM readings")], at: 0)
        }
        return table(metricHeader, rows)
    }

    private func glucoseDistribution(_ report: TherapyReport, _ f: ReportFormatter) -> [String] {
        guard let g = report.summary.glucose else { return [noSensorGlucose] }
        let labels = f.bandLabels(report.thresholds)
        let tir = g.timeInRanges
        var lines = table([String(localized: "Range", bundle: .module, comment: "Table column header: glucose band"),
                           String(localized: "Share", bundle: .module, comment: "Table column header: share of readings")], [
            [labels.veryHigh, f.percent(tir.veryHigh)],
            [labels.high, f.percent(tir.high)],
            [labels.inRange, f.percent(tir.inRange)],
            [labels.low, f.percent(tir.low)],
            [labels.veryLow, f.percent(tir.veryLow)],
            [labels.tight, f.percent(tir.tightRange)],
        ])
        lines.append("")
        lines += table(metricHeader, [
            [String(localized: "Readings", bundle: .module, comment: "Statistic label: number of CGM readings"), "\(g.readingCount)"],
            [String(localized: "Mean", bundle: .module, comment: "Statistic label"), f.glucose(g.mean, withUnit: true)],
            [medianLabel, f.glucose(g.percentiles.p50, withUnit: true)],
            [String(localized: "Standard deviation", bundle: .module, comment: "Statistic label"), f.glucose(g.standardDeviation, withUnit: true)],
            [String(localized: "Coefficient of variation", bundle: .module, comment: "Statistic label"), f.percent(g.coefficientOfVariation)],
            [String(localized: "GMI", bundle: .module, comment: "Statistic label: Glucose Management Indicator"), String(format: "%.1f%%", g.gmi)],
            [String(localized: "Lowest / highest", bundle: .module, comment: "Statistic label: minimum and maximum glucose"),
             "\(f.glucose(g.minimum)) / \(f.glucose(g.maximum, withUnit: true))"],
        ])
        let periods = report.dayPeriods.filter { $0.timeInRanges != nil }
        if !periods.isEmpty {
            lines.append("")
            lines += table([
                String(localized: "Time of day", bundle: .module, comment: "Table column header: part of the day"),
                String(localized: "Very low", bundle: .module, comment: "Glucose band, short"),
                String(localized: "Low", bundle: .module, comment: "Glucose band, short"),
                String(localized: "In range", bundle: .module, comment: "Glucose band, short"),
                String(localized: "High", bundle: .module, comment: "Glucose band, short"),
                String(localized: "Very high", bundle: .module, comment: "Glucose band, short"),
            ], periods.compactMap { entry in
                entry.timeInRanges.map { t in
                    ["\(entry.period.title) (\(entry.period.hoursText))",
                     f.percent(t.veryLow), f.percent(t.low), f.percent(t.inRange), f.percent(t.high), f.percent(t.veryHigh)]
                }
            })
        }
        return lines
    }

    private func distributionByDay(_ report: TherapyReport, _ f: ReportFormatter) -> [String] {
        let rows = report.daily.map { day -> [String] in
            guard let g = day.glucose else { return [f.day(day.day), "–", "–", "–", "–", "–", "–"] }
            let t = g.timeInRanges
            return [f.day(day.day), f.percent(t.veryLow), f.percent(t.low), f.percent(t.inRange),
                    f.percent(t.high), f.percent(t.veryHigh), f.glucose(g.mean)]
        }
        return table([
            dayHeader,
            String(localized: "Very low", bundle: .module, comment: "Glucose band, short"),
            String(localized: "Low", bundle: .module, comment: "Glucose band, short"),
            String(localized: "In range", bundle: .module, comment: "Glucose band, short"),
            String(localized: "High", bundle: .module, comment: "Glucose band, short"),
            String(localized: "Very high", bundle: .module, comment: "Glucose band, short"),
            String(localized: "Mean", bundle: .module, comment: "Statistic label"),
        ], rows)
    }

    private func percentilesByDay(_ report: TherapyReport, _ f: ReportFormatter) -> [String] {
        let rows = report.daily.map { day -> [String] in
            guard let p = day.glucose?.percentiles else { return [f.day(day.day), "–", "–", "–", "–", "–"] }
            return [f.day(day.day), f.glucose(p.p5), f.glucose(p.p25), f.glucose(p.p50), f.glucose(p.p75), f.glucose(p.p95)]
        }
        return table([dayHeader, "5%", "25%", medianLabel, "75%", "95%"], rows)
    }

    /// The calendar as a table: one row per week, one column per weekday, each cell that day's average.
    private func heatmapByDay(_ report: TherapyReport, _ f: ReportFormatter) -> [String] {
        let heatmap = report.dailyGlucoseHeatmap()
        guard !heatmap.daysWithData.isEmpty else { return [noSensorGlucose] }

        var lines = table(metricHeader, heatmap.summaryMetrics(f).map { [$0.label, $0.value + ($0.detail.map { " (\($0))" } ?? "")] })
        lines += [""] + table(
            [String(localized: "Daily average (\(report.displayUnit.rawValue))", bundle: .module, comment: "Table column header; the argument is the glucose unit"),
             String(localized: "Days", bundle: .module, comment: "Table column header: number of days")],
            heatmap.legendBands.map { [heatmap.bandLabel($0, f), "\(heatmap.dayCount(in: $0))"] }
        )
        let rows = heatmap.weeks.map { week -> [String] in
            [f.day(week.start)] + week.cells.map { cell in
                guard let cell else { return "" }
                guard let mean = cell.meanMgdL else { return "–" }
                return f.glucose(mean) + (heatmap.isLowCoverage(cell) ? "\\*" : "")
            }
        }
        let weekHeader = String(localized: "Week of", bundle: .module, comment: "Table column header: the date a calendar week starts")
        lines += [""] + table([weekHeader] + heatmap.weekdays.map(DailyGlucoseHeatmap.weekdayName), rows)
        if !heatmap.lowCoverageDays.isEmpty {
            lines += ["", "\\* " + DailyGlucoseHeatmap.lowCoverageNote]
        }
        return lines
    }

    private func gri(_ report: TherapyReport, _ f: ReportFormatter) -> [String] {
        guard let gri = report.summary.glucose?.gri else { return [noSensorGlucose] }
        var lines = [
            String(localized: "**GRI \(f.number(gri.score)) / 100 — zone \(gri.zone.rawValue)**", bundle: .module,
                   comment: "Markdown GRI headline; arguments are the score and zone letter"),
            "",
        ]
        lines += table([String(localized: "Component", bundle: .module, comment: "Table column header: GRI component"),
                         String(localized: "Value", bundle: .module, comment: "Table column header")], [
            [String(localized: "Very low (<54 mg/dL)", bundle: .module, comment: "GRI band with its fixed threshold"), String(format: "%.1f%%", gri.veryLowPercent)],
            [String(localized: "Low (54–<70 mg/dL)", bundle: .module, comment: "GRI band with its fixed thresholds"), String(format: "%.1f%%", gri.lowPercent)],
            [String(localized: "High (>180–250 mg/dL)", bundle: .module, comment: "GRI band with its fixed thresholds"), String(format: "%.1f%%", gri.highPercent)],
            [String(localized: "Very high (>250 mg/dL)", bundle: .module, comment: "GRI band with its fixed threshold"), String(format: "%.1f%%", gri.veryHighPercent)],
            [String(localized: "Hypoglycemia component", bundle: .module, comment: "GRI component label"), f.number(gri.hypoComponent)],
            [String(localized: "Hyperglycemia component", bundle: .module, comment: "GRI component label"), f.number(gri.hyperComponent)],
        ])
        lines += [
            "",
            String(localized: "3.0 × \(f.number(gri.hypoComponent)) + 1.6 × \(f.number(gri.hyperComponent)) = \(f.number(gri.uncappedScore)) (capped at 100).",
                   bundle: .module, comment: "GRI formula with the computed components"),
            String(localized: "GRI uses fixed thresholds regardless of target range or display unit.", bundle: .module, comment: "GRI explanation"),
        ]
        return lines
    }

    private func totalDailyDose(_ report: TherapyReport, _ f: ReportFormatter) -> [String] {
        let s = report.summary.insulin
        var lines = [
            String(localized: "Average \(f.insulin(s.averageDailyDose)) per day — basal \(f.percent(s.basalFraction, decimals: 0)), bolus \(f.percent(1 - s.basalFraction, decimals: 0)).",
                   bundle: .module, comment: "Total daily dose summary; arguments are units and percentages"),
            "",
        ]
        lines += table([
            dayHeader,
            String(localized: "Total", bundle: .module, comment: "Table column header: total insulin"),
            String(localized: "Basal", bundle: .module, comment: "Insulin type"),
            String(localized: "Bolus", bundle: .module, comment: "Insulin type"),
            String(localized: "Automatic bolus", bundle: .module, comment: "Insulin type: SMB / automatic bolus"),
        ], report.daily.map {
            [f.day($0.day), f.insulin($0.insulin.totalUnits), f.insulin($0.insulin.basalUnits),
             f.insulin($0.insulin.bolusUnits), f.insulin($0.insulin.automaticBolusUnits)]
        })
        let schedules = report.insulinSchedules(f)
        for schedule in schedules {
            lines += [""] + scheduleTable(schedule)
        }
        if !schedules.isEmpty {
            lines += ["", "_\(TherapyReport.settingsNote)_"]
        }
        return lines
    }

    private func therapySettings(_ report: TherapyReport, _ f: ReportFormatter) -> [String] {
        var blocks: [[String]] = []
        if let targets = report.targetSchedule(f) {
            blocks.append(scheduleTable(targets))
        }
        for group in report.settings?.groups ?? [] {
            blocks.append(["**\(group.title)**", ""] + table(
                [String(localized: "Setting", bundle: .module, comment: "Table column header: the name of a therapy setting"),
                 String(localized: "Value", bundle: .module, comment: "Table column header")],
                group.items.map { [$0.label, $0.value] }
            ))
        }
        guard !blocks.isEmpty else {
            return [String(localized: "The app supplied no other settings.", bundle: .module, comment: "Settings section when there is nothing to show")]
        }
        return blocks.joined(separator: [""]).map { $0 } + ["", "_\(TherapyReport.settingsNote)_"]
    }

    private func scheduleTable(_ schedule: PrintedSchedule) -> [String] {
        let heading = schedule.note.map { "**\(schedule.title)** · \($0)" } ?? "**\(schedule.title)**"
        return [heading, ""] + table(
            [String(localized: "From", bundle: .module, comment: "Table column header: time of day a setting starts"),
             String(localized: "Value", bundle: .module, comment: "Table column header")],
            schedule.rows.map { [$0.time, $0.value] }
        )
    }

    private func bolusDistribution(_ report: TherapyReport, _ f: ReportFormatter) -> [String] {
        let s = report.summary.insulin
        let manual = String(localized: "Manual", bundle: .module, comment: "Bolus type: given by the user")
        let automatic = String(localized: "Automatic", bundle: .module, comment: "Bolus type: SMB / automatic bolus")
        let external = String(localized: "External", bundle: .module, comment: "Bolus type: not delivered by the pump")
        var lines = table([
            String(localized: "Bolus type", bundle: .module, comment: "Table column header"),
            String(localized: "Per day", bundle: .module, comment: "Table column header: average per day"),
            String(localized: "Share of bolus", bundle: .module, comment: "Table column header"),
        ], [
            [manual, f.insulin(s.averageDailyManualBolus), share(s.manualBolusUnits, of: s.bolusUnits, f)],
            [String(localized: "Automatic (SMB)", bundle: .module, comment: "Bolus type, long form"), f.insulin(s.averageDailyAutomaticBolus), share(s.automaticBolusUnits, of: s.bolusUnits, f)],
            [String(localized: "External (not pump)", bundle: .module, comment: "Bolus type, long form"), f.insulin(s.averageDailyExternalBolus), share(s.externalBolusUnits, of: s.bolusUnits, f)],
        ])
        lines += ["", String(localized: "\(f.number(s.averageDailyBolusCount)) boluses per day, \(f.number(s.averageDailyAutomaticBolusCount)) of them automatic.", bundle: .module,
                             comment: "Bolus count summary; arguments are average boluses per day and average automatic boluses per day")]
        lines.append("")
        lines += table([dayHeader, manual, automatic, external,
                        String(localized: "Boluses", bundle: .module, comment: "Table column header: number of boluses")], report.daily.map {
            [f.day($0.day), f.insulin($0.insulin.manualBolusUnits), f.insulin($0.insulin.automaticBolusUnits),
             f.insulin($0.insulin.externalBolusUnits), "\($0.insulin.bolusCount)"]
        })
        return lines
    }

    private func carbs(_ report: TherapyReport, _ f: ReportFormatter) -> [String] {
        let s = report.summary.carbs
        var lines = [
            String(localized: "Average \(f.grams(s.averageDailyGrams)) per day in \(f.number(s.averageDailyEntryCount)) entries per day (average \(f.grams(s.averagePerEntry)) per entry, largest \(f.grams(s.largestEntry))).",
                   bundle: .module, comment: "Carbohydrate summary; arguments are grams per day, entries per day, grams per entry and the largest entry"),
        ]
        if s.fatProteinEquivalentGrams > 0 {
            lines.append(String(localized: "Fat/protein carb equivalents: \(f.grams(s.averageDailyFatProteinEquivalentGrams)) per day (not included in the averages above).", bundle: .module,
                                comment: "Note about Trio fat/protein units; the argument is grams per day"))
        }
        lines.append("")
        lines += table([
            dayHeader,
            String(localized: "Carbs", bundle: .module, comment: "Carbohydrates, short: report category heading and table column header"),
            String(localized: "Entries", bundle: .module, comment: "Table column header: number of carb entries"),
            String(localized: "Fat", bundle: .module, comment: "Table column header: grams of fat"),
            String(localized: "Protein", bundle: .module, comment: "Table column header: grams of protein"),
        ], report.daily.map {
            [f.day($0.day), f.grams($0.carbs.totalGrams), "\($0.carbs.entryCount)",
             f.grams($0.carbs.totalFatGrams), f.grams($0.carbs.totalProteinGrams)]
        })
        return lines
    }

    private func dataQuality(_ report: TherapyReport, _ f: ReportFormatter) -> [String] {
        let v = report.validation
        var lines = table([
            String(localized: "Check", bundle: .module, comment: "Table column header: data quality check"),
            String(localized: "Result", bundle: .module, comment: "Table column header"),
        ], [
            [String(localized: "CGM coverage", bundle: .module, comment: "Statistic label: share of time with sensor readings"),
             report.summary.glucose.map { f.percent($0.coverage) } ?? String(localized: "No data", bundle: .module, comment: "Shown when a value cannot be computed")],
            [String(localized: "Basal record coverage", bundle: .module, comment: "Statistic label: share of time covered by basal records"), f.percent(report.summary.insulin.basalCoverage)],
            [String(localized: "Errors", bundle: .module, comment: "Count of validation errors"), "\(v.count(.error))"],
            [String(localized: "Warnings", bundle: .module, comment: "Count of validation warnings"), "\(v.count(.warning))"],
            [String(localized: "Notes", bundle: .module, comment: "Count of informational validation notes"), "\(v.count(.info))"],
        ])
        if !v.issues.isEmpty {
            lines.append("")
            for issue in v.issues.prefix(maximumListedIssues) {
                let when = issue.date.map { " (\(f.dateTime($0)))" } ?? ""
                lines.append("- **\(issue.severity.rawValue)** `\(issue.code)`\(when): \(issue.message)")
            }
            if v.issues.count > maximumListedIssues {
                lines.append(String(localized: "- … \(v.issues.count - maximumListedIssues) more", bundle: .module, comment: "List continuation; the argument is a count"))
            }
        }
        return lines
    }

    // MARK: - Helpers

    private func share(_ part: Double, of total: Double, _ f: ReportFormatter) -> String {
        total > 0 ? f.percent(part / total, decimals: 0) : "–"
    }

    private func table(_ headers: [String], _ rows: [[String]]) -> [String] {
        func row(_ cells: [String]) -> String { "| \(cells.joined(separator: " | ")) |" }
        let separator = "|" + String(repeating: " --- |", count: headers.count)
        return [row(headers), separator] + rows.map(row)
    }
}
