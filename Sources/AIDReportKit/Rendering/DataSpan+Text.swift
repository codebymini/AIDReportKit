import Foundation

extension TherapyReport {
    /// One sentence for readers of per-day charts and tables; `nil` when both days are whole.
    public var partialDayWarning: String? {
        guard let span = dataSpan else { return nil }
        let f = ReportFormatter(report: self)
        switch (isFirstDayPartial, isLastDayPartial) {
        case (true, true):
            return String(localized: "The first and last day are partial: data runs from \(f.dateTime(span.first)) to \(f.dateTime(span.last)), so those two days show less than a full day.",
                          bundle: .module, comment: "Warning on per-day charts; arguments are the first and last data point as date and time")
        case (true, false):
            return String(localized: "The first day is partial: data starts at \(f.dateTime(span.first)), so that day shows less than a full day.",
                          bundle: .module, comment: "Warning on per-day charts; the argument is the first data point as date and time")
        case (false, true):
            return String(localized: "The last day is partial: data ends at \(f.dateTime(span.last)), so that day shows less than a full day.",
                          bundle: .module, comment: "Warning on per-day charts; the argument is the last data point as date and time")
        case (false, false):
            return nil
        }
    }

    /// Whether `section` should carry the partial-day warning: every page with per-day values,
    /// and the data quality page.
    public func partialDayWarning(for section: ReportSection) -> String? {
        section.showsDailyValues || section == .dataQuality ? partialDayWarning : nil
    }
}
