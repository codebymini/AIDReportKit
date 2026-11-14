import AIDReportKit
import Foundation

/// 2026-01-01 00:00 UTC
let t0 = Date(timeIntervalSince1970: 1_767_225_600)
let utc = TimeZone(identifier: "UTC")!
let hour: TimeInterval = 3600
let day: TimeInterval = 86400

func minutes(_ m: Double) -> TimeInterval { m * 60 }

func dataset(
    _ interval: DateInterval = DateInterval(start: t0, duration: day),
    glucose: [GlucoseReading] = [],
    insulin: [InsulinDose] = [],
    carbs: [CarbIntake] = []
) -> TherapyDataset {
    TherapyDataset(interval: interval, source: DataSourceInfo(app: .synthetic, timeZone: utc), glucose: glucose, insulin: insulin, carbs: carbs)
}

/// Sensor readings every 5 minutes with the given values, starting at `start`.
func readings(_ values: [Double], start: Date = t0, every step: TimeInterval = 300) -> [GlucoseReading] {
    values.enumerated().map { index, value in
        GlucoseReading(date: start.addingTimeInterval(Double(index) * step), mgdL: value, sourceID: "g\(index)")
    }
}
