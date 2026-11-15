import Foundation

extension TherapyReport {
    /// One headline number on the overview page: a label, the value and an optional line under it.
    public typealias OverviewMetric = (label: String, value: String, detail: String?)

    /// The overview every renderer shows first: glucose control at a glance, then insulin per day.
    ///
    /// Glucose: time in range (with time below and above), GRI, CV / SD and eA1c (with its
    /// mmol/mol value). Insulin: total daily dose, programmed basal (the basal schedule) and
    /// delivered basal, with delivered as a share of programmed. Empty glucose means no sensor data.
    public func overviewMetrics(_ f: ReportFormatter) -> (glucose: [OverviewMetric], insulin: [OverviewMetric]) {
        var glucose: [OverviewMetric] = []
        if let g = summary.glucose {
            let tir = g.timeInRanges
            glucose = [
                (label: String(localized: "Time in range", bundle: .module, comment: "Statistic label: share of readings between the low and high thresholds"),
                 value: f.percent(tir.inRange),
                 detail: String(localized: "Below \(f.percent(tir.below)) · above \(f.percent(tir.above))", bundle: .module,
                                comment: "Under time in range: time below and time above range")),
                (label: String(localized: "GRI", bundle: .module, comment: "Statistic label: Glycemia Risk Index"),
                 value: f.number(g.gri.score),
                 detail: String(localized: "Zone \(g.gri.zone.rawValue)", bundle: .module, comment: "Under the GRI score: its zone letter A–E")),
                (label: String(localized: "CV / SD", bundle: .module, comment: "Statistic label: coefficient of variation and standard deviation of glucose"),
                 value: "\(f.percent(g.coefficientOfVariation)) / \(f.glucose(g.standardDeviation, withUnit: true))",
                 detail: nil),
                (label: String(localized: "eA1c", bundle: .module, comment: "Statistic label: estimated A1c from mean glucose"),
                 value: String(format: "%.1f%%", g.estimatedA1c),
                 detail: String(localized: "\(f.number(g.estimatedA1cMmolMol, decimals: 0)) mmol/mol", bundle: .module,
                                comment: "Under eA1c in %: the same estimate in mmol/mol (IFCC)")),
            ]
        }

        let i = summary.insulin
        let insulin: [OverviewMetric] = [
            (label: String(localized: "Total daily dose", bundle: .module, comment: "Statistic label: average insulin per day, basal and bolus"),
             value: f.insulin(i.averageDailyDose),
             detail: nil),
            (label: String(localized: "Programmed basal per day", bundle: .module, comment: "Statistic label: basal the basal schedule would deliver per day"),
             value: i.averageDailyProgrammedBasal.map(f.insulin) ?? "–",
             detail: i.averageDailyProgrammedBasal == nil
                 ? String(localized: "No basal schedule", bundle: .module, comment: "Under programmed basal when the app supplied no basal schedule")
                 : String(localized: "Basal schedule", bundle: .module, comment: "Under programmed basal: where the number comes from")),
            (label: String(localized: "Delivered basal per day", bundle: .module, comment: "Statistic label: basal actually delivered per day, temp basals and suspensions included"),
             value: f.insulin(i.averageDailyBasal),
             detail: i.deliveredBasalFraction.map {
                 String(localized: "\(f.percent($0, decimals: 0)) of programmed", bundle: .module,
                        comment: "Under delivered basal: delivered as a share of programmed basal")
             }),
        ]
        return (glucose, insulin)
    }
}
