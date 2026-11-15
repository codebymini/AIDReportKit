#if canImport(SwiftUI) && canImport(Charts) && !os(watchOS)
import AIDReportKit
import Charts
import SwiftUI

/// Built-in page body for each `ReportSection`. All text comes from this target's String Catalog.
@available(iOS 16.0, macOS 13.0, *)
public struct ReportSectionView: View {
    public let section: ReportSection
    public let report: TherapyReport

    public init(section: ReportSection, report: TherapyReport) {
        self.section = section
        self.report = report
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let warning = report.partialDayWarning(for: section) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(ReportColors.veryHigh)
                    Text(warning).fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
                .foregroundStyle(ReportColors.secondaryInk)
            }
            page
        }
        // Charts bin and label dates with the environment's calendar: use the report's, so a
        // follower in another time zone still sees the looper's days.
        .environment(\.calendar, report.dayCalendar)
        .environment(\.timeZone, report.source.timeZone)
    }

    @ViewBuilder
    private var page: some View {
        switch section {
        case .overview: OverviewPage(report: report)
        case .glucoseDistribution: GlucoseDistributionPage(report: report)
        case .glucosePercentileByTime: AGPPage(report: report)
        case .glucoseDistributionByDay: DistributionByDayPage(report: report)
        case .glucosePercentileByDay: PercentilesByDayPage(report: report)
        case .glucoseHeatmapByDay: GlucoseHeatmapPage(report: report)
        case .glycemiaRiskIndex: GRIPage(report: report)
        case .insulinTotalDailyDose: TotalDailyDosePage(report: report)
        case .insulinBolusDistribution: BolusDistributionPage(report: report)
        case .carbsTotals: CarbsPage(report: report)
        case .dataQuality: DataQualityPage(report: report)
        }
    }
}

// MARK: - Shared pieces

/// Chart plot labels identify data series internally and are never printed on the page, so they
/// go through the plain-String overload and stay out of the String Catalog.
private func plotLabel(_ label: String) -> String { label }

extension Color {
    /// 0xRRGGBB in sRGB.
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

enum ReportColors {
    static let veryLow = Color(red: 0.55, green: 0.00, blue: 0.00)
    static let low = Color(red: 0.89, green: 0.16, blue: 0.16)
    static let inRange = Color(red: 0.20, green: 0.64, blue: 0.33)
    static let high = Color(red: 0.98, green: 0.76, blue: 0.18)
    static let veryHigh = Color(red: 0.95, green: 0.50, blue: 0.10)
    static let basal = Color(red: 0.25, green: 0.47, blue: 0.85)
    static let bolus = Color(red: 0.55, green: 0.35, blue: 0.80)
    static let automatic = Color(red: 0.45, green: 0.72, blue: 0.95)
    static let external = Color(red: 0.60, green: 0.60, blue: 0.60)
    static let carbs = Color(red: 0.95, green: 0.60, blue: 0.15)
    static let agpOuter = Color(red: 0.25, green: 0.47, blue: 0.85).opacity(0.18)
    static let agpInner = Color(red: 0.25, green: 0.47, blue: 0.85).opacity(0.40)
    static let agpMedian = Color(red: 0.10, green: 0.25, blue: 0.60)

    /// Daily-average heatmap: green, yellow and red for in range, high and very high.
    static let heatInRange = inRange
    static let heatHigh = high
    static let heatVeryHigh = Color(red: 0.89, green: 0.16, blue: 0.16)
    /// A whole day averaging below range: dark red, so it cannot be mistaken for very high.
    static let heatLow = veryLow
    static let heatNoData = Color(hex: 0xF0EFEC)
    static let ink = Color(hex: 0x0B0B0B)
    static let secondaryInk = Color(hex: 0x52514E)
}

/// Labels shared by several pages and chart legends.
enum Labels {
    static var noSensorGlucose: String {
        String(localized: "No sensor glucose in this period.", bundle: .module, comment: "Shown instead of glucose statistics when there is no CGM data")
    }
    static var median: String { String(localized: "Median", bundle: .module, comment: "Statistic or chart series: median glucose") }
    static var mean: String { String(localized: "Mean", bundle: .module, comment: "Statistic label") }
    static var gmi: String { String(localized: "GMI", bundle: .module, comment: "Statistic label: Glucose Management Indicator") }
    static var cv: String { String(localized: "Coefficient of variation", bundle: .module, comment: "Statistic label") }
    static var coverage: String { String(localized: "CGM coverage", bundle: .module, comment: "Statistic label: share of time with sensor readings") }
    static var basal: String { String(localized: "Basal", bundle: .module, comment: "Insulin type / chart series") }
    static var bolus: String { String(localized: "Bolus", bundle: .module, comment: "Insulin type / chart series") }
    static var manual: String { String(localized: "Manual", bundle: .module, comment: "Bolus type / chart series: given by the user") }
    static var automatic: String { String(localized: "Automatic", bundle: .module, comment: "Bolus type / chart series: SMB / automatic bolus") }
    static var external: String { String(localized: "External", bundle: .module, comment: "Bolus type / chart series: not delivered by the pump") }
    static var veryLow: String { String(localized: "Very low", bundle: .module, comment: "Glucose band, short") }
    static var low: String { String(localized: "Low", bundle: .module, comment: "Glucose band, short") }
    static var inRange: String { String(localized: "In range", bundle: .module, comment: "Glucose band, short") }
    static var high: String { String(localized: "High", bundle: .module, comment: "Glucose band, short") }
    static var veryHigh: String { String(localized: "Very high", bundle: .module, comment: "Glucose band, short") }

    static var automaticBolusPerDay: String {
        String(localized: "Automatic bolus per day", bundle: .module, comment: "Statistic label: average SMB / automatic bolus units per day")
    }
    static var carbEntriesPerDay: String {
        String(localized: "Carb entries per day", bundle: .module, comment: "Statistic label: average number of carb entries per day")
    }
}

@available(iOS 16.0, macOS 13.0, *)
struct MetricGrid: View {
    let metrics: [(String, String)]
    var columns = 3
    /// Smaller values and wrapping labels, for a grid that shares the page width with a chart.
    var compact = false

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
            ForEach(Array(stride(from: 0, to: metrics.count, by: columns)), id: \.self) { start in
                GridRow(alignment: .top) {
                    ForEach(start ..< min(start + columns, metrics.count), id: \.self) { index in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(metrics[index].0)
                                .font(.caption)
                                .foregroundStyle(Color.gray)
                                .fixedSize(horizontal: false, vertical: true)
                            value(metrics[index].1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func value(_ text: String) -> some View {
        Text(text).font(compact ? .headline : .title3.weight(.semibold)).monospacedDigit()
    }
}

@available(iOS 16.0, macOS 13.0, *)
struct NoDataView: View {
    var text = Labels.noSensorGlucose
    var body: some View {
        Text(text).font(.callout).foregroundStyle(Color.gray)
    }
}

@available(iOS 16.0, macOS 13.0, *)
struct TimeInRangeBar: View {
    let tir: TimeInRanges
    let thresholds: GlucoseThresholds
    let formatter: ReportFormatter
    var height: CGFloat = 200

    private static let barWidth: CGFloat = 44
    private static let connectorWidth: CGFloat = 22
    private static let rowHeight: CGFloat = 22
    private static let gap: CGFloat = 1

    /// Top to bottom, the way the bar is stacked.
    private var bands: [(label: String, share: Double, color: Color)] {
        let labels = formatter.bandLabels(thresholds)
        return [
            (labels.veryHigh, tir.veryHigh, ReportColors.veryHigh),
            (labels.high, tir.high, ReportColors.high),
            (labels.inRange, tir.inRange, ReportColors.inRange),
            (labels.low, tir.low, ReportColors.low),
            (labels.veryLow, tir.veryLow, ReportColors.veryLow),
        ]
    }

    /// Height of each segment; together with the gaps between them they fill `height`.
    private var segmentHeights: [CGFloat] {
        let usable = height - Self.gap * CGFloat(bands.count - 1)
        return bands.map { max(0, usable * CGFloat($0.share)) }
    }

    /// The vertical middle of each segment, measured from the top of the bar.
    private var segmentCenters: [CGFloat] {
        var top: CGFloat = 0
        return segmentHeights.map { segment in
            defer { top += segment + Self.gap }
            return top + segment / 2
        }
    }

    /// Where each label sits: at its segment's middle when there is room, otherwise pushed just
    /// far enough that rows do not overlap. A connector line ties each label to its segment.
    private var labelCenters: [CGFloat] {
        var ys = segmentCenters
        guard !ys.isEmpty else { return ys }
        ys[0] = max(ys[0], Self.rowHeight / 2)
        for index in ys.indices.dropFirst() {
            ys[index] = max(ys[index], ys[index - 1] + Self.rowHeight)
        }
        ys[ys.count - 1] = min(ys[ys.count - 1], height - Self.rowHeight / 2)
        for index in ys.indices.dropLast().reversed() {
            ys[index] = min(ys[index], ys[index + 1] - Self.rowHeight)
        }
        return ys
    }

    var body: some View {
        let heights = segmentHeights
        let centers = segmentCenters
        let labels = labelCenters
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: Self.gap) {
                    ForEach(bands.indices, id: \.self) { index in
                        Rectangle().fill(bands[index].color).frame(height: heights[index])
                    }
                }
                .frame(width: Self.barWidth, height: height, alignment: .top)

                Path { path in
                    for index in bands.indices {
                        path.move(to: CGPoint(x: 3, y: centers[index]))
                        path.addLine(to: CGPoint(x: Self.connectorWidth - 3, y: labels[index]))
                    }
                }
                .stroke(Color.gray.opacity(0.7), lineWidth: 0.5)
                .frame(width: Self.connectorWidth, height: height)

                ZStack(alignment: .topLeading) {
                    ForEach(bands.indices, id: \.self) { index in
                        HStack(spacing: 6) {
                            Circle().fill(bands[index].color).frame(width: 9, height: 9)
                            Text(bands[index].label).font(.callout).lineLimit(1).minimumScaleFactor(0.8)
                            Spacer(minLength: 8)
                            Text(formatter.percent(bands[index].share)).font(.callout.weight(.semibold)).monospacedDigit()
                        }
                        .frame(height: Self.rowHeight)
                        .offset(y: labels[index] - Self.rowHeight / 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: height, alignment: .topLeading)
            }
            HStack(spacing: 6) {
                Text(formatter.bandLabels(thresholds).tight).font(.callout).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                Text(formatter.percent(tir.tightRange)).font(.callout.weight(.semibold)).monospacedDigit()
            }
            .padding(.leading, Self.barWidth + Self.connectorWidth)
        }
    }
}

@available(iOS 16.0, macOS 13.0, *)
extension View {
    func chartFrame(_ height: CGFloat = 300) -> some View {
        frame(height: height).font(.caption2)
    }

    /// Day labels on the report's clock. Charts prints dates on the device's clock, which for a
    /// follower in another time zone names the day before or after the one the bar stands for.
    func reportDayAxis(_ report: TherapyReport) -> some View {
        let format = Date.FormatStyle(date: .omitted, time: .omitted, calendar: report.dayCalendar, timeZone: report.source.timeZone)
            .day()
            .month(.abbreviated)
        return chartXAxis {
            AxisMarks(values: .automatic) { _ in
                AxisGridLine()
                AxisTick()
                AxisValueLabel(format: format)
            }
        }
    }
}

// MARK: - Pages

@available(iOS 16.0, macOS 13.0, *)
struct OverviewPage: View {
    let report: TherapyReport

    // Fixed sizes rather than text styles, so the page reads the same rendered on an iPhone as on a Mac.
    private static let headingFont = Font.system(size: 11, weight: .semibold)
    private static let labelFont = Font.system(size: 8.5)
    private static let valueFont = Font.system(size: 14, weight: .semibold)
    private static let columns = 4

    var body: some View {
        let f = ReportFormatter(report: report)
        let metrics = report.overviewMetrics(f)
        VStack(alignment: .leading, spacing: 22) {
            group(String(localized: "Glucose", bundle: .module, comment: "Overview page heading above the glucose numbers")) {
                if let g = report.summary.glucose, !metrics.glucose.isEmpty {
                    tiles(metrics.glucose)
                    TimeInRangeStrip(tir: g.timeInRanges, thresholds: report.thresholds, formatter: f)
                    if AGPChart.hasData(report) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(String(localized: "Glucose by time of day (\(report.displayUnit.rawValue)), all days overlaid: median with 25–75% and 5–95% bands.",
                                        bundle: .module, comment: "Caption of the small AGP chart on the overview page; the argument is the glucose unit"))
                                .font(Self.labelFont)
                                .foregroundStyle(Color.gray)
                            AGPChart(report: report, axisFont: Self.labelFont).frame(height: 220)
                        }
                        .padding(.top, 4)
                    }
                } else {
                    NoDataView()
                }
            }
            group(String(localized: "Insulin", bundle: .module, comment: "Overview page heading above the insulin numbers")) {
                tiles(metrics.insulin)
            }
        }
    }

    private func group(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(Self.headingFont)
            content()
        }
    }

    /// Rows of `columns` equal tiles, so glucose and insulin numbers line up in the same columns.
    private func tiles(_ metrics: [TherapyReport.OverviewMetric]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(stride(from: 0, to: metrics.count, by: Self.columns)), id: \.self) { start in
                let row = Array(metrics[start ..< min(start + Self.columns, metrics.count)])
                HStack(alignment: .top, spacing: 14) {
                    ForEach(row.indices, id: \.self) { index in
                        tile(row[index])
                    }
                    ForEach(row.count ..< Self.columns, id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                    }
                }
            }
        }
    }

    private func tile(_ metric: TherapyReport.OverviewMetric) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(metric.label).font(Self.labelFont).foregroundStyle(Color.gray)
            Text(metric.value)
                .font(Self.valueFont)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let detail = metric.detail {
                Text(detail).font(Self.labelFont).monospacedDigit().foregroundStyle(Color.gray)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The five glucose ranges as one thin horizontal bar, very low on the left, with each range's
/// cut-offs and share listed underneath (tiny segments cannot carry their own label).
@available(iOS 16.0, macOS 13.0, *)
struct TimeInRangeStrip: View {
    let tir: TimeInRanges
    let thresholds: GlucoseThresholds
    let formatter: ReportFormatter
    var height: CGFloat = 10

    private static let gap: CGFloat = 1.5
    private static let font = Font.system(size: 8.5)

    /// Left to right.
    private var bands: [(label: String, share: Double, color: Color)] {
        let labels = formatter.bandLabels(thresholds)
        return [
            (labels.veryLow, tir.veryLow, ReportColors.veryLow),
            (labels.low, tir.low, ReportColors.low),
            (labels.inRange, tir.inRange, ReportColors.inRange),
            (labels.high, tir.high, ReportColors.high),
            (labels.veryHigh, tir.veryHigh, ReportColors.veryHigh),
        ]
    }

    var body: some View {
        let bands = self.bands
        let visible = bands.filter { $0.share > 0 }
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                let usable = geometry.size.width - Self.gap * CGFloat(max(visible.count - 1, 0))
                HStack(spacing: Self.gap) {
                    ForEach(visible.indices, id: \.self) { index in
                        Rectangle()
                            .fill(visible[index].color)
                            .frame(width: max(0, usable * CGFloat(visible[index].share)))
                    }
                }
            }
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 2))
            HStack(alignment: .top, spacing: 8) {
                ForEach(bands.indices, id: \.self) { index in
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        RoundedRectangle(cornerRadius: 1.5).fill(bands[index].color).frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(bands[index].label).foregroundStyle(Color.gray).lineLimit(1).minimumScaleFactor(0.8)
                            Text(formatter.percent(bands[index].share)).fontWeight(.semibold).monospacedDigit()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(Self.font)
        }
    }
}

@available(iOS 16.0, macOS 13.0, *)
struct GlucoseDistributionPage: View {
    let report: TherapyReport

    private struct Slice: Identifiable {
        let time: String
        let band: String
        let share: Double
        var id: String { "\(time)-\(band)" }
    }

    var body: some View {
        let f = ReportFormatter(report: report)
        if let g = report.summary.glucose {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 22) {
                    TimeInRangeBar(tir: g.timeInRanges, thresholds: report.thresholds, formatter: f)
                        .frame(width: 305)
                    MetricGrid(metrics: [
                        (Labels.mean, f.glucose(g.mean, withUnit: true)),
                        (Labels.median, f.glucose(g.percentiles.p50, withUnit: true)),
                        (String(localized: "Standard deviation", bundle: .module, comment: "Statistic label"), f.glucose(g.standardDeviation, withUnit: true)),
                        (Labels.cv, f.percent(g.coefficientOfVariation)),
                        (Labels.gmi, String(format: "%.1f%%", g.gmi)),
                        (String(localized: "Lowest / highest", bundle: .module, comment: "Statistic label: minimum and maximum glucose"),
                         "\(f.glucose(g.minimum)) / \(f.glucose(g.maximum))"),
                    ], columns: 2, compact: true)
                }
                Divider()
                timeOfDay(f)
            }
        } else {
            NoDataView()
        }
    }

    /// The same ranges split by time of day, all days overlaid: one full-height bar per bucket.
    @ViewBuilder
    private func timeOfDay(_ f: ReportFormatter) -> some View {
        // Bottom to top, the way each bar is stacked.
        let bands = [Labels.veryLow, Labels.low, Labels.inRange, Labels.high, Labels.veryHigh]
        let buckets = report.agp.buckets
        let slices = buckets.flatMap { bucket -> [Slice] in
            guard let t = bucket.timeInRanges else { return [] }
            let time = f.timeOfDay(minute: bucket.startMinute)
            return zip(bands, [t.veryLow, t.low, t.inRange, t.high, t.veryHigh]).map { Slice(time: time, band: $0.0, share: $0.1 * 100) }
        }
        if !slices.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "By time of day", bundle: .module, comment: "Chart heading: glucose ranges split by time of day")).font(.headline)
                Text(String(localized: "Share of readings in each range for each hour of the day, all days overlaid.", bundle: .module,
                            comment: "Chart caption for the time-of-day range breakdown"))
                    .font(.caption)
                    .foregroundStyle(Color.gray)
                Chart(slices) { slice in
                    BarMark(x: .value(plotLabel("Time"), slice.time), y: .value(plotLabel("Share (%)"), slice.share))
                        .foregroundStyle(by: .value(plotLabel("Range"), slice.band))
                }
                .chartForegroundStyleScale([
                    bands[0]: ReportColors.veryLow,
                    bands[1]: ReportColors.low,
                    bands[2]: ReportColors.inRange,
                    bands[3]: ReportColors.high,
                    bands[4]: ReportColors.veryHigh,
                ])
                .chartXScale(domain: buckets.map { f.timeOfDay(minute: $0.startMinute) }, range: .plotDimension(startPadding: 12, endPadding: 12))
                .chartXAxis {
                    AxisMarks(values: buckets.filter { $0.startMinute % 180 == 0 }.map { f.timeOfDay(minute: $0.startMinute) }) { _ in
                        AxisGridLine()
                        AxisValueLabel()
                    }
                }
                .chartYScale(domain: 0 ... 100)
                .chartFrame(170)
            }
        }
    }
}

@available(iOS 16.0, macOS 13.0, *)
struct AGPPage: View {
    let report: TherapyReport

    private struct Point: Identifiable {
        let minute: Int
        let p: Percentiles
        var id: Int { minute }
    }

    var body: some View {
        let f = ReportFormatter(report: report)
        let unit = report.displayUnit
        let half = report.agp.bucketMinutes / 2
        let points = report.agp.buckets.compactMap { b in b.percentiles.map { Point(minute: b.startMinute + half, p: $0) } }
        let outer = String(localized: "5–95%", bundle: .module, comment: "Chart series: 5th to 95th percentile band")
        let inner = String(localized: "25–75%", bundle: .module, comment: "Chart series: 25th to 75th percentile band")
        let median = Labels.median
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Percentiles of \(unit.rawValue) by time of day, all days overlaid. Shaded: 5–95% and 25–75%; line: median.",
                        bundle: .module, comment: "AGP chart caption; the argument is the glucose unit"))
                .font(.caption)
                .foregroundStyle(Color.gray)
            if points.isEmpty {
                NoDataView()
            } else {
                Chart {
                    ForEach(points) { point in
                        AreaMark(x: .value(plotLabel("Time"), point.minute),
                                 yStart: .value(plotLabel("5%"), unit.fromMgdL(point.p.p5)),
                                 yEnd: .value(plotLabel("95%"), unit.fromMgdL(point.p.p95)))
                            .foregroundStyle(by: .value(plotLabel("Band"), outer))
                            .interpolationMethod(.catmullRom)
                    }
                    ForEach(points) { point in
                        AreaMark(x: .value(plotLabel("Time"), point.minute),
                                 yStart: .value(plotLabel("25%"), unit.fromMgdL(point.p.p25)),
                                 yEnd: .value(plotLabel("75%"), unit.fromMgdL(point.p.p75)))
                            .foregroundStyle(by: .value(plotLabel("Band"), inner))
                            .interpolationMethod(.catmullRom)
                    }
                    ForEach(points) { point in
                        LineMark(x: .value(plotLabel("Time"), point.minute), y: .value(plotLabel("Median"), unit.fromMgdL(point.p.p50)))
                            .foregroundStyle(by: .value(plotLabel("Band"), median))
                            .interpolationMethod(.catmullRom)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    RuleMark(y: .value(plotLabel("Low"), unit.fromMgdL(report.thresholds.low)))
                        .foregroundStyle(ReportColors.low.opacity(0.7))
                    RuleMark(y: .value(plotLabel("High"), unit.fromMgdL(report.thresholds.high)))
                        .foregroundStyle(ReportColors.high.opacity(0.9))
                }
                .chartForegroundStyleScale([
                    outer: ReportColors.agpOuter,
                    inner: ReportColors.agpInner,
                    median: ReportColors.agpMedian,
                ])
                .chartXScale(domain: 0 ... 1440)
                .chartXAxis {
                    AxisMarks(values: Array(stride(from: 0, through: 1440, by: 180))) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let minute = value.as(Int.self) { Text(f.timeOfDay(minute: minute % 1440)) }
                        }
                    }
                }
                .chartFrame(380)
            }
        }
    }
}

/// Glucose percentiles by time of day, all days overlaid (the ambulatory glucose profile): 5–95%
/// and 25–75% bands, the median, and lines at the low and high thresholds. Drawn small on the
/// overview, whose caption names the bands, so it has no legend.
@available(iOS 16.0, macOS 13.0, *)
struct AGPChart: View {
    let report: TherapyReport
    /// Axis labels; Charts does not take them from the surrounding font.
    let axisFont: Font

    private struct Point: Identifiable {
        let minute: Int
        let p: Percentiles
        var id: Int { minute }
    }

    static func hasData(_ report: TherapyReport) -> Bool {
        report.agp.buckets.contains { $0.percentiles != nil }
    }

    /// Each bucket at its middle (00:30, 01:30 … 23:30 for hours), plus midnight at both edges so
    /// the profile spans the whole day. The day wraps around, so midnight lies halfway between the
    /// last bucket and the first.
    private static func points(_ agp: AGPProfile) -> [Point] {
        let half = agp.bucketMinutes / 2
        let points = agp.buckets.compactMap { b in b.percentiles.map { Point(minute: b.startMinute + half, p: $0) } }
        guard let first = agp.buckets.first?.percentiles ?? agp.buckets.last?.percentiles,
              let last = agp.buckets.last?.percentiles ?? agp.buckets.first?.percentiles
        else { return points }
        func mean(_ a: Double, _ b: Double) -> Double { (a + b) / 2 }
        let midnight = Percentiles(p5: mean(first.p5, last.p5), p25: mean(first.p25, last.p25), p50: mean(first.p50, last.p50),
                                   p75: mean(first.p75, last.p75), p95: mean(first.p95, last.p95))
        return [Point(minute: 0, p: midnight)] + points + [Point(minute: 1440, p: midnight)]
    }

    var body: some View {
        let f = ReportFormatter(report: report)
        let unit = report.displayUnit
        let points = Self.points(report.agp)
        let outer = String(localized: "5–95%", bundle: .module, comment: "Chart series: 5th to 95th percentile band")
        let inner = String(localized: "25–75%", bundle: .module, comment: "Chart series: 25th to 75th percentile band")
        let median = Labels.median
        Chart {
            ForEach(points) { point in
                AreaMark(x: .value(plotLabel("Time"), point.minute),
                         yStart: .value(plotLabel("5%"), unit.fromMgdL(point.p.p5)),
                         yEnd: .value(plotLabel("95%"), unit.fromMgdL(point.p.p95)))
                    .foregroundStyle(by: .value(plotLabel("Band"), outer))
                    .interpolationMethod(.catmullRom)
            }
            ForEach(points) { point in
                AreaMark(x: .value(plotLabel("Time"), point.minute),
                         yStart: .value(plotLabel("25%"), unit.fromMgdL(point.p.p25)),
                         yEnd: .value(plotLabel("75%"), unit.fromMgdL(point.p.p75)))
                    .foregroundStyle(by: .value(plotLabel("Band"), inner))
                    .interpolationMethod(.catmullRom)
            }
            ForEach(points) { point in
                LineMark(x: .value(plotLabel("Time"), point.minute), y: .value(plotLabel("Median"), unit.fromMgdL(point.p.p50)))
                    .foregroundStyle(by: .value(plotLabel("Band"), median))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            RuleMark(y: .value(plotLabel("Low"), unit.fromMgdL(report.thresholds.low)))
                .foregroundStyle(ReportColors.low.opacity(0.7))
            RuleMark(y: .value(plotLabel("High"), unit.fromMgdL(report.thresholds.high)))
                .foregroundStyle(ReportColors.high.opacity(0.9))
        }
        .chartForegroundStyleScale([
            outer: ReportColors.agpOuter,
            inner: ReportColors.agpInner,
            median: ReportColors.agpMedian,
        ])
        .chartXScale(domain: 0 ... 1440)
        .chartXAxis {
            AxisMarks(values: Array(stride(from: 0, through: 1440, by: 180))) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let minute = value.as(Int.self) { Text(f.timeOfDay(minute: minute % 1440)) }
                }
                .font(axisFont)
            }
        }
        .chartYAxis {
            AxisMarks { _ in
                AxisGridLine()
                AxisTick()
                AxisValueLabel().font(axisFont)
            }
        }
        .chartLegend(.hidden)
    }
}

@available(iOS 16.0, macOS 13.0, *)
struct DistributionByDayPage: View {
    let report: TherapyReport

    private struct Slice: Identifiable {
        let day: Date
        let band: String
        let share: Double
        var id: String { "\(day.timeIntervalSince1970)-\(band)" }
    }

    var body: some View {
        let bands = [Labels.veryLow, Labels.low, Labels.inRange, Labels.high, Labels.veryHigh]
        let slices = report.daily.flatMap { day -> [Slice] in
            guard let t = day.glucose?.timeInRanges else { return [] }
            return zip(bands, [t.veryLow, t.low, t.inRange, t.high, t.veryHigh])
                .map { Slice(day: day.day, band: $0.0, share: $0.1 * 100) }
        }
        if slices.isEmpty {
            NoDataView()
        } else {
            Chart(slices) { slice in
                BarMark(x: .value(plotLabel("Day"), slice.day, unit: .day, calendar: report.dayCalendar), y: .value(plotLabel("Share (%)"), slice.share))
                    .foregroundStyle(by: .value(plotLabel("Range"), slice.band))
            }
            .chartForegroundStyleScale([
                bands[0]: ReportColors.veryLow,
                bands[1]: ReportColors.low,
                bands[2]: ReportColors.inRange,
                bands[3]: ReportColors.high,
                bands[4]: ReportColors.veryHigh,
            ])
            .chartYScale(domain: 0 ... 100)
            .reportDayAxis(report)
            .chartFrame(420)
        }
    }
}

@available(iOS 16.0, macOS 13.0, *)
struct PercentilesByDayPage: View {
    let report: TherapyReport

    private struct Day: Identifiable {
        let day: Date
        let p: Percentiles
        var id: Date { day }
    }

    var body: some View {
        let unit = report.displayUnit
        let days = report.daily.compactMap { d in d.glucose.map { Day(day: d.day, p: $0.percentiles) } }
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Per day: whisker 5–95%, box 25–75%, dot median (\(unit.rawValue)).", bundle: .module,
                        comment: "Chart caption; the argument is the glucose unit"))
                .font(.caption)
                .foregroundStyle(Color.gray)
            if days.isEmpty {
                NoDataView()
            } else {
                Chart {
                    ForEach(days) { d in
                        RuleMark(x: .value(plotLabel("Day"), d.day, unit: .day, calendar: report.dayCalendar),
                                 yStart: .value(plotLabel("5%"), unit.fromMgdL(d.p.p5)),
                                 yEnd: .value(plotLabel("95%"), unit.fromMgdL(d.p.p95)))
                            .foregroundStyle(ReportColors.agpMedian.opacity(0.5))
                        BarMark(x: .value(plotLabel("Day"), d.day, unit: .day, calendar: report.dayCalendar),
                                yStart: .value(plotLabel("25%"), unit.fromMgdL(d.p.p25)),
                                yEnd: .value(plotLabel("75%"), unit.fromMgdL(d.p.p75)))
                            .foregroundStyle(ReportColors.agpInner)
                        PointMark(x: .value(plotLabel("Day"), d.day, unit: .day, calendar: report.dayCalendar), y: .value(plotLabel("Median"), unit.fromMgdL(d.p.p50)))
                            .foregroundStyle(ReportColors.agpMedian)
                            .symbolSize(18)
                    }
                    RuleMark(y: .value(plotLabel("Low"), unit.fromMgdL(report.thresholds.low)))
                        .foregroundStyle(ReportColors.low.opacity(0.7))
                    RuleMark(y: .value(plotLabel("High"), unit.fromMgdL(report.thresholds.high)))
                        .foregroundStyle(ReportColors.high.opacity(0.9))
                }
                .reportDayAxis(report)
                .chartFrame(420)
            }
        }
    }
}

@available(iOS 16.0, macOS 13.0, *)
struct GlucoseHeatmapPage: View {
    let report: TherapyReport

    private static let weekLabelWidth: CGFloat = 38

    var body: some View {
        let heatmap = report.dailyGlucoseHeatmap()
        let f = ReportFormatter(report: report)
        if heatmap.daysWithData.isEmpty {
            NoDataView()
        } else {
            VStack(alignment: .leading, spacing: 14) {
                summary(heatmap, f)
                calendar(heatmap, f)
                legend(heatmap, f)
            }
        }
    }

    /// One compact row, so three months of weeks still fit below it.
    private func summary(_ heatmap: DailyGlucoseHeatmap, _ f: ReportFormatter) -> some View {
        let metrics = heatmap.summaryMetrics(f)
        return HStack(alignment: .top, spacing: 12) {
            ForEach(metrics.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 2) {
                    Text(metrics[index].label).font(.caption).foregroundStyle(Color.gray)
                    Text(metrics[index].value).font(.title3.weight(.semibold)).monospacedDigit()
                    if let detail = metrics[index].detail {
                        Text(detail).font(.caption2).monospacedDigit().foregroundStyle(Color.gray)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Up to 14 week rows (3 months) have to fit the space the other charts use.
    private func rowHeight(weeks: Int) -> CGFloat {
        min(44, max(16, (345 / CGFloat(max(weeks, 1))).rounded(.down) - 2))
    }

    private func calendar(_ heatmap: DailyGlucoseHeatmap, _ f: ReportFormatter) -> some View {
        let height = rowHeight(weeks: heatmap.weeks.count)
        return Grid(horizontalSpacing: 2, verticalSpacing: 2) {
            GridRow {
                Color.clear.frame(width: Self.weekLabelWidth, height: 1)
                ForEach(heatmap.weekdays, id: \.self) { weekday in
                    Text(DailyGlucoseHeatmap.weekdayName(weekday))
                        .font(.caption2)
                        .foregroundStyle(Color.gray)
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(heatmap.weeks) { week in
                GridRow {
                    Text(f.shortDay(week.start))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(Color.gray)
                        .frame(width: Self.weekLabelWidth, alignment: .leading)
                    ForEach(0 ..< 7, id: \.self) { index in
                        cellView(week.cells[index], heatmap, f, height: height)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cellView(_ cell: DailyGlucoseHeatmap.Cell?, _ heatmap: DailyGlucoseHeatmap, _ f: ReportFormatter, height: CGFloat) -> some View {
        if let cell {
            let band = heatmap.band(of: cell)
            // Near-black reads best on green and yellow, white on the reds.
            let isDark = band == .veryHigh || band == .low
            let value = cell.meanMgdL.map { f.glucose($0) + (heatmap.isLowCoverage(cell) ? "*" : "") } ?? "–"
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(band.map(Self.color) ?? ReportColors.heatNoData)
                Text(verbatim: value)
                    .font(.system(size: height < 26 ? 9 : 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(isDark ? Color.white : (band == nil ? ReportColors.secondaryInk : ReportColors.ink))
            }
            .overlay(alignment: .topLeading) {
                Text(verbatim: "\(cell.dayOfMonth)")
                    .font(.system(size: 6.5))
                    .foregroundStyle(isDark ? Color.white.opacity(0.85) : ReportColors.ink.opacity(0.7))
                    .padding(.leading, 4)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
        } else {
            Color.clear.frame(maxWidth: .infinity).frame(height: height)
        }
    }

    private static func color(_ band: DailyGlucoseHeatmap.Band) -> Color {
        switch band {
        case .low: return ReportColors.heatLow
        case .inRange: return ReportColors.heatInRange
        case .high: return ReportColors.heatHigh
        case .veryHigh: return ReportColors.heatVeryHigh
        }
    }

    /// Each color with the range it stands for and how many days fell in it.
    private func legend(_ heatmap: DailyGlucoseHeatmap, _ f: ReportFormatter) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                ForEach(heatmap.legendBands, id: \.self) { band in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(Self.color(band)).frame(width: 12, height: 8)
                        Text(heatmap.bandLabel(band, f))
                        Text(verbatim: "\(heatmap.dayCount(in: band))").fontWeight(.semibold).foregroundStyle(ReportColors.ink)
                    }
                }
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(ReportColors.heatNoData).frame(width: 12, height: 8)
                    Text(String(localized: "No data", bundle: .module, comment: "Shown when there is nothing to show: a value that cannot be computed, or a heatmap day without sensor glucose"))
                }
            }
            Text(String(localized: "Each cell is one day's average glucose (\(report.displayUnit.rawValue)), colored by the range it falls in. The number after each range is how many days fell in it.",
                        bundle: .module, comment: "Heatmap caption; the argument is the glucose unit"))
                .fixedSize(horizontal: false, vertical: true)
            if !heatmap.lowCoverageDays.isEmpty {
                Text(verbatim: "* " + DailyGlucoseHeatmap.lowCoverageNote)
            }
        }
        .font(.caption2)
        .foregroundStyle(Color.gray)
    }
}

@available(iOS 16.0, macOS 13.0, *)
struct GRIPage: View {
    let report: TherapyReport

    var body: some View {
        let f = ReportFormatter(report: report)
        if let gri = report.summary.glucose?.gri {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(String(localized: "GRI", bundle: .module, comment: "Statistic label: Glycemia Risk Index")).font(.headline)
                    Text(f.number(gri.score)).font(.largeTitle.bold())
                    Text(verbatim: "/ 100").foregroundStyle(Color.gray)
                    Spacer()
                    Text(String(localized: "Zone \(gri.zone.rawValue)", bundle: .module, comment: "GRI zone; the argument is a letter A–E")).font(.headline)
                }
                HStack(alignment: .top, spacing: 24) {
                    GRIRiskGrid(gri: gri, formatter: f)
                        .frame(width: 300, height: 300)
                    MetricGrid(metrics: [
                        (String(localized: "Very low (<54 mg/dL)", bundle: .module, comment: "GRI band with its fixed threshold"), String(format: "%.1f%%", gri.veryLowPercent)),
                        (String(localized: "Low (54–<70 mg/dL)", bundle: .module, comment: "GRI band with its fixed thresholds"), String(format: "%.1f%%", gri.lowPercent)),
                        (String(localized: "Hypoglycemia component", bundle: .module, comment: "GRI component label"), f.number(gri.hypoComponent)),
                        (String(localized: "High (>180–250 mg/dL)", bundle: .module, comment: "GRI band with its fixed thresholds"), String(format: "%.1f%%", gri.highPercent)),
                        (String(localized: "Very high (>250 mg/dL)", bundle: .module, comment: "GRI band with its fixed threshold"), String(format: "%.1f%%", gri.veryHighPercent)),
                        (String(localized: "Hyperglycemia component", bundle: .module, comment: "GRI component label"), f.number(gri.hyperComponent)),
                    ], columns: 1)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "Weighted hypoglycemia: 3 × \(f.number(gri.hypoComponent)) = \(f.number(gri.weightedHypoComponent))", bundle: .module,
                                comment: "GRI formula line with computed numbers"))
                    Text(String(localized: "Weighted hyperglycemia: 1.6 × \(f.number(gri.hyperComponent)) = \(f.number(gri.weightedHyperComponent))", bundle: .module,
                                comment: "GRI formula line with computed numbers"))
                    Text(String(localized: "Combined: \(f.number(gri.uncappedScore)), capped at 100.", bundle: .module,
                                comment: "GRI formula result; the argument is the uncapped score"))
                }
                .font(.callout)
                Text(String(localized: "GRI combines low and high glucose exposure into a 0–100 score; lower is less risk. It uses fixed thresholds regardless of target range or display unit. Short periods and sensor gaps make it less representative.",
                            bundle: .module, comment: "GRI explanation on the report page"))
                    .font(.caption)
                    .foregroundStyle(Color.gray)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            NoDataView()
        }
    }
}

/// The GRI grid: hypoglycemia component across, hyperglycemia component up. Each zone is the area
/// under the line 3 × hypo + 1.6 × hyper = its upper score, so the zones stack as triangles from
/// the origin; the dot is this report. Same construction and colors as the grids in Trio and
/// LoopFollow.
@available(iOS 16.0, macOS 13.0, *)
struct GRIRiskGrid: View {
    let gri: GlycemiaRiskIndex
    let formatter: ReportFormatter

    private struct Zone: Identifiable {
        let letter: String
        let range: String
        let upperScore: Double
        let color: Color
        var id: String { letter }
    }

    private static let zones = [
        Zone(letter: "A", range: "0–20", upperScore: 20, color: Color(red: 0.48, green: 0.74, blue: 0.46)),
        Zone(letter: "B", range: ">20–40", upperScore: 40, color: Color(red: 0.98, green: 0.96, blue: 0.48)),
        Zone(letter: "C", range: ">40–60", upperScore: 60, color: Color(red: 1.00, green: 0.82, blue: 0.49)),
        Zone(letter: "D", range: ">60–80", upperScore: 80, color: Color(red: 0.95, green: 0.46, blue: 0.48)),
        Zone(letter: "E", range: ">80–100", upperScore: 100, color: Color(red: 0.79, green: 0.57, blue: 0.55)),
    ]
    private static let tickCount = 6
    private static let legendSize = CGSize(width: 104, height: 76)

    /// The axes cover at least the published grid (30 × 60) and grow to keep the dot inside.
    private var xMax: Double { max(30, (gri.hypoComponent / 5).rounded(.up) * 5) }
    private var yMax: Double { max(60, (gri.hyperComponent / 10).rounded(.up) * 10) }

    private func tick(_ value: Double) -> String {
        formatter.number(value, decimals: value == value.rounded() ? 0 : 1)
    }

    var body: some View {
        GeometryReader { geometry in
            let plot = CGRect(x: 40, y: 6, width: geometry.size.width - 48, height: geometry.size.height - 42)
            ZStack(alignment: .topLeading) {
                zoneBands(in: plot.size)
                    .frame(width: plot.width, height: plot.height)
                    .clipped()
                    .offset(x: plot.minX, y: plot.minY)
                Path(plot).stroke(Color.gray, lineWidth: 0.5)

                ForEach(0 ... Self.tickCount, id: \.self) { step in
                    let fraction = Double(step) / Double(Self.tickCount)
                    Text(verbatim: tick(fraction * xMax))
                        .position(x: plot.minX + fraction * plot.width, y: plot.maxY + 9)
                    Text(verbatim: tick(fraction * yMax))
                        .position(x: plot.minX - 13, y: plot.maxY - fraction * plot.height)
                }
                Text(String(localized: "Hypoglycemia component (%)", bundle: .module, comment: "GRI grid horizontal axis title"))
                    .position(x: plot.midX, y: plot.maxY + 26)
                Text(String(localized: "Hyperglycemia component (%)", bundle: .module, comment: "GRI grid vertical axis title"))
                    .fixedSize()
                    .rotationEffect(.degrees(-90))
                    .position(x: 8, y: plot.midY)

                legend
                    .position(x: plot.maxX - Self.legendSize.width / 2 - 8, y: plot.minY + Self.legendSize.height / 2 + 8)

                // This report, with a white ring so it reads on every zone color.
                Circle()
                    .fill(ReportColors.ink)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
                    .position(x: plot.minX + gri.hypoComponent / xMax * plot.width, y: plot.maxY - gri.hyperComponent / yMax * plot.height)
            }
            .font(.system(size: 8))
            .foregroundStyle(ReportColors.secondaryInk)
        }
    }

    /// Largest zone first, so each smaller triangle is painted over the one before.
    private func zoneBands(in size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Color.white
            ForEach(Self.zones.reversed()) { zone in
                Path { path in
                    path.move(to: CGPoint(x: 0, y: size.height))
                    path.addLine(to: CGPoint(x: zone.upperScore / 3 / xMax * size.width, y: size.height))
                    path.addLine(to: CGPoint(x: 0, y: size.height - zone.upperScore / 1.6 / yMax * size.height))
                    path.closeSubpath()
                }
                .fill(zone.color)
            }
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Self.zones) { zone in
                HStack(spacing: 5) {
                    Rectangle().fill(zone.color).frame(width: 9, height: 9)
                    Text(String(localized: "Zone \(zone.letter) (\(zone.range))", bundle: .module,
                                comment: "GRI grid legend entry; arguments are the zone letter and its score range"))
                        .foregroundStyle(ReportColors.ink)
                }
            }
        }
        .padding(6)
        .frame(width: Self.legendSize.width, height: Self.legendSize.height, alignment: .leading)
        .background(Color.white)
        .overlay(Rectangle().stroke(Color.gray, lineWidth: 0.5))
    }
}

@available(iOS 16.0, macOS 13.0, *)
struct TotalDailyDosePage: View {
    let report: TherapyReport

    private struct Part: Identifiable {
        let day: Date
        let kind: String
        let units: Double
        var id: String { "\(day.timeIntervalSince1970)-\(kind)" }
    }

    var body: some View {
        let f = ReportFormatter(report: report)
        let s = report.summary.insulin
        let basal = Labels.basal
        let bolus = Labels.bolus
        let parts = report.daily.flatMap { d in
            [Part(day: d.day, kind: basal, units: d.insulin.basalUnits),
             Part(day: d.day, kind: bolus, units: d.insulin.bolusUnits)]
        }
        VStack(alignment: .leading, spacing: 20) {
            MetricGrid(metrics: [
                (String(localized: "Average daily dose", bundle: .module, comment: "Statistic label: total daily insulin"), f.insulin(s.averageDailyDose)),
                (String(localized: "Basal per day", bundle: .module, comment: "Statistic label: average basal insulin per day"), f.insulin(s.averageDailyBasal)),
                (String(localized: "Bolus per day", bundle: .module, comment: "Statistic label: average bolus insulin per day"), f.insulin(s.averageDailyBolus)),
                (String(localized: "Basal share", bundle: .module, comment: "Statistic label: basal share of total insulin"), f.percent(s.basalFraction, decimals: 0)),
                (String(localized: "Basal record coverage", bundle: .module, comment: "Statistic label: share of time covered by basal records"), f.percent(s.basalCoverage, decimals: 0)),
                (String(localized: "Suspended per day", bundle: .module, comment: "Statistic label: average pump suspension time per day"), f.duration(s.averageDailySuspendedDuration)),
            ])
            Chart(parts) { part in
                BarMark(x: .value(plotLabel("Day"), part.day, unit: .day, calendar: report.dayCalendar), y: .value(plotLabel("Units"), part.units))
                    .foregroundStyle(by: .value(plotLabel("Type"), part.kind))
            }
            .chartForegroundStyleScale([basal: ReportColors.basal, bolus: ReportColors.bolus])
            .reportDayAxis(report)
            .chartFrame(360)
        }
    }
}

@available(iOS 16.0, macOS 13.0, *)
struct BolusDistributionPage: View {
    let report: TherapyReport

    private struct Part: Identifiable {
        let day: Date
        let kind: String
        let units: Double
        var id: String { "\(day.timeIntervalSince1970)-\(kind)" }
    }

    var body: some View {
        let f = ReportFormatter(report: report)
        let s = report.summary.insulin
        let manual = Labels.manual
        let automatic = Labels.automatic
        let external = Labels.external
        let parts = report.daily.flatMap { d in
            [Part(day: d.day, kind: manual, units: d.insulin.manualBolusUnits),
             Part(day: d.day, kind: automatic, units: d.insulin.automaticBolusUnits),
             Part(day: d.day, kind: external, units: d.insulin.externalBolusUnits)]
        }
        VStack(alignment: .leading, spacing: 20) {
            MetricGrid(metrics: [
                (String(localized: "Manual bolus per day", bundle: .module, comment: "Statistic label: average user-given bolus units per day"), f.insulin(s.averageDailyManualBolus)),
                (Labels.automaticBolusPerDay, f.insulin(s.averageDailyAutomaticBolus)),
                (String(localized: "External bolus per day", bundle: .module, comment: "Statistic label: average units per day not delivered by the pump"), f.insulin(s.averageDailyExternalBolus)),
                (String(localized: "Boluses per day", bundle: .module, comment: "Statistic label: average number of boluses per day"), f.number(s.averageDailyBolusCount)),
                (String(localized: "Automatic boluses per day", bundle: .module, comment: "Statistic label: average number of automatic boluses per day"), f.number(s.averageDailyAutomaticBolusCount)),
            ])
            Chart(parts) { part in
                BarMark(x: .value(plotLabel("Day"), part.day, unit: .day, calendar: report.dayCalendar), y: .value(plotLabel("Units"), part.units))
                    .foregroundStyle(by: .value(plotLabel("Type"), part.kind))
            }
            .chartForegroundStyleScale([
                manual: ReportColors.bolus,
                automatic: ReportColors.automatic,
                external: ReportColors.external,
            ])
            .reportDayAxis(report)
            .chartFrame(360)
        }
    }
}

@available(iOS 16.0, macOS 13.0, *)
struct CarbsPage: View {
    let report: TherapyReport

    var body: some View {
        let f = ReportFormatter(report: report)
        let s = report.summary.carbs
        VStack(alignment: .leading, spacing: 20) {
            MetricGrid(metrics: metrics(s, f))
            Chart(report.daily, id: \.day) { day in
                BarMark(x: .value(plotLabel("Day"), day.day, unit: .day, calendar: report.dayCalendar), y: .value(plotLabel("Carbs (g)"), day.carbs.totalGrams))
                    .foregroundStyle(ReportColors.carbs)
            }
            .reportDayAxis(report)
            .chartFrame(360)
        }
    }

    /// Everything per day or per entry; fat and protein only when any was logged.
    private func metrics(_ s: CarbStatistics, _ f: ReportFormatter) -> [(String, String)] {
        var metrics = [
            (String(localized: "Average per day", bundle: .module, comment: "Statistic label: carbs per day"), f.grams(s.averageDailyGrams)),
            (Labels.carbEntriesPerDay, f.number(s.averageDailyEntryCount)),
            (String(localized: "Average per entry", bundle: .module, comment: "Statistic label: carbs per entry"), f.grams(s.averagePerEntry)),
            (String(localized: "Largest entry", bundle: .module, comment: "Statistic label: largest carb entry"), f.grams(s.largestEntry)),
        ]
        if s.totalFatGrams > 0 || s.totalProteinGrams > 0 {
            metrics.append((String(localized: "Fat / protein per day", bundle: .module, comment: "Statistic label: average grams of fat and protein per day"),
                            "\(f.grams(s.averageDailyFatGrams)) / \(f.grams(s.averageDailyProteinGrams))"))
        }
        if s.fatProteinEquivalentGrams > 0 {
            metrics.append((String(localized: "Fat/protein carb equivalents per day", bundle: .module, comment: "Statistic label: Trio fat/protein units as carbs, average per day"),
                            f.grams(s.averageDailyFatProteinEquivalentGrams)))
        }
        return metrics
    }
}

@available(iOS 16.0, macOS 13.0, *)
struct DataQualityPage: View {
    let report: TherapyReport

    var body: some View {
        let f = ReportFormatter(report: report)
        let v = report.validation
        VStack(alignment: .leading, spacing: 16) {
            MetricGrid(metrics: [
                (Labels.coverage, report.summary.glucose.map { f.percent($0.coverage) }
                    ?? String(localized: "No data", bundle: .module, comment: "Shown when there is nothing to show: a value that cannot be computed, or a heatmap day without sensor glucose")),
                (String(localized: "Basal record coverage", bundle: .module, comment: "Statistic label: share of time covered by basal records"), f.percent(report.summary.insulin.basalCoverage)),
                (String(localized: "Errors", bundle: .module, comment: "Count of validation errors"), "\(v.count(.error))"),
                (String(localized: "Warnings", bundle: .module, comment: "Count of validation warnings"), "\(v.count(.warning))"),
                (String(localized: "Notes", bundle: .module, comment: "Count of informational validation notes"), "\(v.count(.info))"),
            ])
            if v.issues.isEmpty {
                Text(String(localized: "No issues found.", bundle: .module, comment: "Data quality page when validation found nothing"))
                    .font(.callout)
                    .foregroundStyle(Color.gray)
            }
        }
    }

}
#endif
