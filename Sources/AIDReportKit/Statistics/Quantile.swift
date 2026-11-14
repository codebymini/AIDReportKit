import Foundation

enum Quantile {
    /// Linear interpolation between closest ranks (Excel PERCENTILE.INC, NumPy default).
    /// `sorted` must be ascending and non-empty; `p` is in 0...1.
    static func value(_ p: Double, sorted: [Double]) -> Double {
        precondition(!sorted.isEmpty)
        let position = min(max(p, 0), 1) * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let fraction = position - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
    }
}

/// The 5/25/50/75/95 percentiles used by AGP-style charts.
public struct Percentiles: Hashable, Codable, Sendable {
    public var p5: Double
    public var p25: Double
    public var p50: Double
    public var p75: Double
    public var p95: Double

    public init(p5: Double, p25: Double, p50: Double, p75: Double, p95: Double) {
        self.p5 = p5
        self.p25 = p25
        self.p50 = p50
        self.p75 = p75
        self.p95 = p95
    }

    /// `nil` for empty input.
    public init?(values: [Double]) {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        self.init(
            p5: Quantile.value(0.05, sorted: sorted),
            p25: Quantile.value(0.25, sorted: sorted),
            p50: Quantile.value(0.50, sorted: sorted),
            p75: Quantile.value(0.75, sorted: sorted),
            p95: Quantile.value(0.95, sorted: sorted)
        )
    }
}
