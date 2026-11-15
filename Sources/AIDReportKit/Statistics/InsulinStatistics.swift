import Foundation

public struct InsulinStatistics: Hashable, Codable, Sendable {
    public var totalUnits: Double
    /// Scheduled + temp basal.
    public var basalUnits: Double
    public var bolusUnits: Double
    /// User-initiated boluses delivered by the pump.
    public var manualBolusUnits: Double
    /// SMBs / automatic boluses.
    public var automaticBolusUnits: Double
    /// Logged, not pump-delivered (pen, inhaled).
    public var externalBolusUnits: Double
    public var bolusCount: Int
    public var automaticBolusCount: Int
    public var suspendedDuration: TimeInterval
    /// Interval length in days (fractional for partial days).
    public var days: Double
    /// Total daily dose: `totalUnits / days`.
    public var averageDailyDose: Double
    /// `basalUnits / totalUnits` (0 when there is no insulin).
    public var basalFraction: Double
    /// Fraction of the interval covered by basal records. Below ~0.9 the basal total undercounts;
    /// provide a `BasalSchedule` so gaps are filled with scheduled basal.
    public var basalCoverage: Double
    /// What the basal schedule (the profile programmed in the app) would have delivered over the
    /// time there is data, before any temp basal or suspension; `nil` without a schedule.
    /// Compare with `basalUnits`, what was delivered, to see how far the loop moved basal.
    public var programmedBasalUnits: Double?

    // MARK: Per-day averages (what reports show; the totals above depend on the period length)

    public var averageDailyBasal: Double { perDay(basalUnits) }
    public var averageDailyProgrammedBasal: Double? { programmedBasalUnits.map(perDay) }
    /// Delivered basal as a share of programmed basal (1 = as scheduled); `nil` without a schedule.
    public var deliveredBasalFraction: Double? {
        guard let programmed = programmedBasalUnits, programmed > 0 else { return nil }
        return basalUnits / programmed
    }
    public var averageDailyBolus: Double { perDay(bolusUnits) }
    public var averageDailyManualBolus: Double { perDay(manualBolusUnits) }
    public var averageDailyAutomaticBolus: Double { perDay(automaticBolusUnits) }
    public var averageDailyExternalBolus: Double { perDay(externalBolusUnits) }
    /// Boluses of any kind per day.
    public var averageDailyBolusCount: Double { perDay(Double(bolusCount)) }
    public var averageDailyAutomaticBolusCount: Double { perDay(Double(automaticBolusCount)) }
    /// Suspended time per day, in seconds.
    public var averageDailySuspendedDuration: TimeInterval { perDay(suspendedDuration) }

    private func perDay(_ total: Double) -> Double { days > 0 ? total / days : 0 }

    /// - Parameters:
    ///   - schedule: The basal schedule, for `programmedBasalUnits`.
    ///   - window: The time there is data. Programmed basal only counts there, as delivered basal
    ///     does, so a period that starts before the first record is not read as a shortfall.
    public static func compute(
        _ doses: [InsulinDose],
        interval: DateInterval,
        schedule: BasalSchedule? = nil,
        within window: DateInterval? = nil
    ) -> InsulinStatistics {
        let clamped = doses.compactMap { $0.clamped(to: interval) }
        let boluses = clamped.filter { $0.kind == .bolus }
        let basal = clamped.filter { $0.kind == .basal || $0.kind == .tempBasal }
        let suspends = clamped.filter { $0.kind == .suspend }

        let basalUnits = basal.reduce(0) { $0 + $1.units }
        let bolusUnits = boluses.reduce(0) { $0 + $1.units }
        let automatic = boluses.filter { $0.isAutomatic && !$0.isExternal }
        let external = boluses.filter(\.isExternal)
        let total = basalUnits + bolusUnits
        let days = interval.duration / 86400

        return InsulinStatistics(
            totalUnits: total,
            basalUnits: basalUnits,
            bolusUnits: bolusUnits,
            manualBolusUnits: bolusUnits - automatic.reduce(0) { $0 + $1.units } - external.reduce(0) { $0 + $1.units },
            automaticBolusUnits: automatic.reduce(0) { $0 + $1.units },
            externalBolusUnits: external.reduce(0) { $0 + $1.units },
            bolusCount: boluses.count,
            automaticBolusCount: automatic.count,
            suspendedDuration: suspends.reduce(0) { $0 + $1.duration },
            days: days,
            averageDailyDose: days > 0 ? total / days : 0,
            basalFraction: total > 0 ? basalUnits / total : 0,
            basalCoverage: BasalTimeline.coverage(clamped, in: interval),
            programmedBasalUnits: schedule.map { schedule in
                guard let span = interval.intersection(with: window ?? interval), span.duration > 0 else { return 0 }
                return schedule.doses(in: span).reduce(0) { $0 + $1.units }
            }
        )
    }
}
