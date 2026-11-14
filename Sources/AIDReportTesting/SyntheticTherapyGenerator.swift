import AIDReportKit
import Foundation

/// Deterministic pseudo-random numbers (SplitMix64), so synthetic datasets are identical across runs.
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Standard normal sample (Box–Muller).
    public mutating func normal(mean: Double = 0, sd: Double = 1) -> Double {
        let u1 = Double.random(in: Double.ulpOfOne ..< 1, using: &self)
        let u2 = Double.random(in: 0 ..< 1, using: &self)
        return mean + sd * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

/// Builds a realistic-looking, fully deterministic dataset: CGM with a daily rhythm, meal
/// excursions and noise; meals with matching manual boluses; 30-minute loop temp basals; SMBs.
public struct SyntheticTherapyGenerator: Sendable {
    public struct Meal: Sendable {
        public var minuteOfDay: Int
        public var grams: ClosedRange<Double>
        public init(minuteOfDay: Int, grams: ClosedRange<Double>) {
            self.minuteOfDay = minuteOfDay
            self.grams = grams
        }
    }

    public var seed: UInt64 = 42
    /// 2026-01-01 00:00 UTC.
    public var start = Date(timeIntervalSince1970: 1_767_225_600)
    public var days = 14
    public var timeZone = TimeZone(identifier: "UTC")!
    public var cgmInterval: TimeInterval = 300
    public var dropoutProbability = 0.01
    public var baseGlucose = 125.0
    /// Kept low enough that consecutive 5-minute readings stay under the rate-of-change limit,
    /// so synthetic data validates without warnings (CGM values are already smoothed).
    public var noiseSD = 4.0
    public var scheduledBasalRate = 0.8
    public var carbRatio = 10.0
    public var smbProbability = 0.04
    public var meals: [Meal] = [
        Meal(minuteOfDay: 7 * 60 + 30, grams: 30 ... 60),
        Meal(minuteOfDay: 12 * 60 + 30, grams: 40 ... 70),
        Meal(minuteOfDay: 18 * 60 + 30, grams: 50 ... 80),
    ]

    public init(seed: UInt64 = 42, days: Int = 14) {
        self.seed = seed
        self.days = days
    }

    public var interval: DateInterval {
        DateInterval(start: start, duration: Double(days) * 86400)
    }

    public func makeDataset(app: HostApp = .synthetic) -> TherapyDataset {
        var rng = SeededGenerator(seed: seed)
        var carbs: [CarbIntake] = []
        var insulin: [InsulinDose] = []

        for day in 0 ..< days {
            for (index, meal) in meals.enumerated() {
                let jitter = Double(Int.random(in: -30 ... 30, using: &rng)) * 60
                let date = start.addingTimeInterval(Double(day) * 86400 + Double(meal.minuteOfDay) * 60 + jitter)
                let grams = Double.random(in: meal.grams, using: &rng).rounded()
                carbs.append(CarbIntake(date: date, grams: grams, absorptionTime: 3 * 3600, sourceID: "syn-carb-\(day)-\(index)"))
                insulin.append(.bolus(at: date, units: (grams / carbRatio * 20).rounded() / 20, sourceID: "syn-bolus-\(day)-\(index)"))
            }
        }

        var t = start
        var tempIndex = 0
        while t < interval.end {
            let rate = (scheduledBasalRate * Double.random(in: 0 ... 2, using: &rng) * 20).rounded() / 20
            insulin.append(.basal(.tempBasal, start: t, end: t.addingTimeInterval(1800), ratePerHour: rate, sourceID: "syn-temp-\(tempIndex)"))
            t.addTimeInterval(1800)
            tempIndex += 1
        }

        var glucose: [GlucoseReading] = []
        var index = 0
        t = start
        while t < interval.end {
            defer { t.addTimeInterval(cgmInterval); index += 1 }
            if Double.random(in: 0 ..< 1, using: &rng) < dropoutProbability { continue }
            let value = min(400, max(40, expectedGlucose(at: t, carbs: carbs) + rng.normal(sd: noiseSD)))
            glucose.append(GlucoseReading(date: t, mgdL: value.rounded(), sourceID: "syn-bg-\(index)"))
            if Double.random(in: 0 ..< 1, using: &rng) < smbProbability {
                let units = Double(Int.random(in: 1 ... 5, using: &rng)) / 10
                insulin.append(.bolus(at: t.addingTimeInterval(30), units: units, isAutomatic: true, sourceID: "syn-smb-\(index)"))
            }
        }

        return TherapyDataset(
            interval: interval,
            source: DataSourceInfo(app: app, appVersion: "synthetic", timeZone: timeZone),
            glucose: glucose,
            insulin: insulin,
            carbs: carbs
        )
    }

    private func expectedGlucose(at date: Date, carbs: [CarbIntake]) -> Double {
        let minuteOfDay = date.timeIntervalSince(start).truncatingRemainder(dividingBy: 86400) / 60
        var value = baseGlucose + 25 * sin(2 * .pi * (minuteOfDay - 240) / 1440)
        for entry in carbs {
            let hours = date.timeIntervalSince(entry.date) / 3600
            // Gamma-shaped excursion peaking at 1 h; by 8 h it is < 1 mg/dL, so no step at the cutoff.
            if hours > 0 && hours < 8 {
                value += entry.grams * 1.6 * hours * exp(1 - hours)
            }
        }
        return value
    }
}
