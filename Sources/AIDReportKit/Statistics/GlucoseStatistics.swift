import Foundation

/// Range boundaries in mg/dL. Defaults follow the 2019 international consensus on time in range.
public struct GlucoseThresholds: Hashable, Codable, Sendable {
    /// Below this is "very low" (level 2 hypoglycemia).
    public var veryLow: Double
    /// Below this is "low".
    public var low: Double
    /// Above this is "high".
    public var high: Double
    /// Above this is "very high".
    public var veryHigh: Double
    /// Upper bound of time in tight range (TITR), lower bound is `low`.
    public var tightHigh: Double

    public init(veryLow: Double = 54, low: Double = 70, high: Double = 180, veryHigh: Double = 250, tightHigh: Double = 140) {
        self.veryLow = veryLow
        self.low = low
        self.high = high
        self.veryHigh = veryHigh
        self.tightHigh = tightHigh
    }

    public static let consensus = GlucoseThresholds()
}

/// Fractions (0...1) of sensor readings in each band. The five main bands sum to 1.
public struct TimeInRanges: Hashable, Codable, Sendable {
    /// `< veryLow`
    public var veryLow: Double
    /// `veryLow ..< low`
    public var low: Double
    /// `low ... high`
    public var inRange: Double
    /// `high <.. veryHigh`
    public var high: Double
    /// `> veryHigh`
    public var veryHigh: Double
    /// `low ... tightHigh`; overlaps `inRange`.
    public var tightRange: Double

    public var below: Double { veryLow + low }
    public var above: Double { high + veryHigh }

    public init(veryLow: Double, low: Double, inRange: Double, high: Double, veryHigh: Double, tightRange: Double) {
        self.veryLow = veryLow
        self.low = low
        self.inRange = inRange
        self.high = high
        self.veryHigh = veryHigh
        self.tightRange = tightRange
    }

    public init(values: [Double], thresholds: GlucoseThresholds) {
        let n = Double(max(values.count, 1))
        func share(_ predicate: (Double) -> Bool) -> Double { Double(values.filter(predicate).count) / n }
        self.init(
            veryLow: share { $0 < thresholds.veryLow },
            low: share { $0 >= thresholds.veryLow && $0 < thresholds.low },
            inRange: share { $0 >= thresholds.low && $0 <= thresholds.high },
            high: share { $0 > thresholds.high && $0 <= thresholds.veryHigh },
            veryHigh: share { $0 > thresholds.veryHigh },
            tightRange: share { $0 >= thresholds.low && $0 <= thresholds.tightHigh }
        )
    }
}

/// Glycemia Risk Index (Klonoff et al. 2023).
///
/// Always computed from the fixed consensus thresholds (54/70/180/250 mg/dL), regardless of the
/// user's target range or display unit, so scores are comparable across people and apps.
public struct GlycemiaRiskIndex: Hashable, Codable, Sendable {
    public enum Zone: String, Codable, Sendable { case A, B, C, D, E }

    /// Percent (0...100) of readings in each band.
    public var veryLowPercent: Double
    public var lowPercent: Double
    public var highPercent: Double
    public var veryHighPercent: Double
    /// `veryLow + 0.8 × low`
    public var hypoComponent: Double
    /// `veryHigh + 0.5 × high`
    public var hyperComponent: Double
    /// `3.0 × hypo + 1.6 × hyper`, before capping.
    public var uncappedScore: Double
    /// 0...100
    public var score: Double
    public var zone: Zone

    public init(values: [Double]) {
        let tir = TimeInRanges(values: values, thresholds: .consensus)
        veryLowPercent = tir.veryLow * 100
        lowPercent = tir.low * 100
        highPercent = tir.high * 100
        veryHighPercent = tir.veryHigh * 100
        hypoComponent = veryLowPercent + 0.8 * lowPercent
        hyperComponent = veryHighPercent + 0.5 * highPercent
        uncappedScore = 3.0 * hypoComponent + 1.6 * hyperComponent
        score = min(100, uncappedScore)
        switch score {
        case ...20: zone = .A
        case ...40: zone = .B
        case ...60: zone = .C
        case ...80: zone = .D
        default: zone = .E
        }
    }

    public var weightedHypoComponent: Double { 3.0 * hypoComponent }
    public var weightedHyperComponent: Double { 1.6 * hyperComponent }
}

/// Summary statistics for sensor glucose over an interval. All values in mg/dL.
public struct GlucoseStatistics: Hashable, Codable, Sendable {
    public var readingCount: Int
    public var mean: Double
    /// Sample standard deviation (n − 1).
    public var standardDeviation: Double
    /// SD / mean, as a fraction. ≤ 0.36 is the consensus stability target.
    public var coefficientOfVariation: Double
    /// Glucose Management Indicator, % (3.31 + 0.02392 × mean mg/dL).
    public var gmi: Double
    /// Estimated A1c, % (NGSP), from the ADAG relation (mean mg/dL + 46.7) / 28.7, as Trio and
    /// LoopFollow show it next to GMI.
    public var estimatedA1c: Double { (mean + 46.7) / 28.7 }
    /// Estimated A1c in mmol/mol (IFCC), converted the way Trio does: 10.929 × (NGSP − 2.152).
    public var estimatedA1cMmolMol: Double { 10.929 * (estimatedA1c - 2.152) }
    public var minimum: Double
    public var maximum: Double
    public var percentiles: Percentiles
    public var timeInRanges: TimeInRanges
    public var gri: GlycemiaRiskIndex
    /// Fraction of `slotDuration` slots in the interval with at least one reading.
    /// ≥ 0.70 over 14 days is the consensus minimum for reliable statistics.
    public var coverage: Double

    /// Sensor readings only; `nil` when there are none in the interval.
    public static func compute(
        _ readings: [GlucoseReading],
        interval: DateInterval,
        thresholds: GlucoseThresholds = .consensus,
        slotDuration: TimeInterval = 300
    ) -> GlucoseStatistics? {
        let sensor = readings.filter { $0.kind == .sensor && interval.containsHalfOpen($0.date) }
        let values = sensor.map(\.mgdL)
        guard let percentiles = Percentiles(values: values), let minimum = values.min(), let maximum = values.max() else {
            return nil
        }
        let n = Double(values.count)
        let mean = values.reduce(0, +) / n
        let variance = values.count > 1 ? values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / (n - 1) : 0
        let sd = variance.squareRoot()
        return GlucoseStatistics(
            readingCount: values.count,
            mean: mean,
            standardDeviation: sd,
            coefficientOfVariation: mean > 0 ? sd / mean : 0,
            gmi: 3.31 + 0.02392 * mean,
            minimum: minimum,
            maximum: maximum,
            percentiles: percentiles,
            timeInRanges: TimeInRanges(values: values, thresholds: thresholds),
            gri: GlycemiaRiskIndex(values: values),
            coverage: coverage(of: sensor.map(\.date), in: interval, slotDuration: slotDuration)
        )
    }

    /// Fraction of `slotDuration` slots in `interval` that contain at least one date.
    /// Works for both 1-minute (Libre) and 5-minute (Dexcom) sensors.
    public static func coverage(of dates: [Date], in interval: DateInterval, slotDuration: TimeInterval = 300) -> Double {
        let slotCount = Int((interval.duration / slotDuration).rounded(.up))
        guard slotCount > 0 else { return 0 }
        let filled = Set(dates.filter { interval.containsHalfOpen($0) }.map {
            Int($0.timeIntervalSince(interval.start) / slotDuration)
        })
        return Double(filled.count) / Double(slotCount)
    }
}
