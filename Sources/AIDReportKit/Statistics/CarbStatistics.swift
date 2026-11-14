import Foundation

public struct CarbStatistics: Hashable, Codable, Sendable {
    /// Carbs actually entered; excludes fat/protein equivalents.
    public var totalGrams: Double
    /// Entries with carbs; a fat/protein-only meal is not counted.
    public var entryCount: Int
    public var averagePerEntry: Double
    public var largestEntry: Double
    public var days: Double
    public var averageDailyGrams: Double
    public var totalFatGrams: Double
    public var totalProteinGrams: Double
    /// Carb equivalents generated from fat/protein (Trio FPU), reported separately.
    public var fatProteinEquivalentGrams: Double

    // MARK: Per-day averages (what reports show; the totals above depend on the period length)

    /// Carb entries per day.
    public var averageDailyEntryCount: Double { perDay(Double(entryCount)) }
    public var averageDailyFatGrams: Double { perDay(totalFatGrams) }
    public var averageDailyProteinGrams: Double { perDay(totalProteinGrams) }
    public var averageDailyFatProteinEquivalentGrams: Double { perDay(fatProteinEquivalentGrams) }

    private func perDay(_ total: Double) -> Double { days > 0 ? total / days : 0 }

    public static func compute(_ entries: [CarbIntake], interval: DateInterval) -> CarbStatistics {
        let inInterval = entries.filter { interval.containsHalfOpen($0.date) }
        let carbs = inInterval.filter { !$0.isFatProteinEquivalent }
        // A fat/protein-only meal (Trio stores it as an entry with 0 g of carbs) still carries its
        // fat and protein, but it is not a carb entry.
        let carbEntries = carbs.filter { $0.grams > 0 }
        let total = carbEntries.reduce(0) { $0 + $1.grams }
        let days = interval.duration / 86400
        return CarbStatistics(
            totalGrams: total,
            entryCount: carbEntries.count,
            averagePerEntry: carbEntries.isEmpty ? 0 : total / Double(carbEntries.count),
            largestEntry: carbEntries.map(\.grams).max() ?? 0,
            days: days,
            averageDailyGrams: days > 0 ? total / days : 0,
            totalFatGrams: carbs.reduce(0) { $0 + ($1.fatGrams ?? 0) },
            totalProteinGrams: carbs.reduce(0) { $0 + ($1.proteinGrams ?? 0) },
            fatProteinEquivalentGrams: inInterval.filter(\.isFatProteinEquivalent).reduce(0) { $0 + $1.grams }
        )
    }
}
