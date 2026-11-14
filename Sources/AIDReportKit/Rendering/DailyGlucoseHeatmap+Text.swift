import Foundation

extension DailyGlucoseHeatmap {
    /// Headline numbers shown with the calendar by every renderer; `detail` is the date of an extreme.
    public func summaryMetrics(_ f: ReportFormatter) -> [(label: String, value: String, detail: String?)] {
        var metrics: [(label: String, value: String, detail: String?)] = [(
            label: String(localized: "Days with data", bundle: .module, comment: "Heatmap statistic label: days that have sensor glucose"),
            value: String(localized: "\(daysWithData.count) of \(days.count)", bundle: .module,
                          comment: "Heatmap statistic value; arguments are days with data and days in the period"),
            detail: nil
        )]
        if let lowest, let mean = lowest.meanMgdL {
            metrics.append((
                label: String(localized: "Lowest daily average", bundle: .module, comment: "Heatmap statistic label"),
                value: f.glucose(mean, withUnit: true),
                detail: f.day(lowest.day)
            ))
        }
        if let highest, let mean = highest.meanMgdL {
            metrics.append((
                label: String(localized: "Highest daily average", bundle: .module, comment: "Heatmap statistic label"),
                value: f.glucose(mean, withUnit: true),
                detail: f.day(highest.day)
            ))
        }
        return metrics
    }

    /// The band's name with its cut-offs in the report's unit, e.g. "In range (70–180)".
    public func bandLabel(_ band: Band, _ f: ReportFormatter) -> String {
        let labels = f.bandLabels(thresholds)
        switch band {
        case .low:
            return String(localized: "Low (<\(f.glucose(thresholds.low)))", bundle: .module,
                          comment: "Heatmap band for a daily average below the low threshold; the argument is that threshold")
        case .inRange: return labels.inRange
        case .high: return labels.high
        case .veryHigh: return labels.veryHigh
        }
    }

    /// Explains the asterisk on averages that rest on little data.
    public static var lowCoverageNote: String {
        String(localized: "Under 50% CGM coverage that day.", bundle: .module, comment: "Footnote for heatmap days marked with an asterisk")
    }
}
