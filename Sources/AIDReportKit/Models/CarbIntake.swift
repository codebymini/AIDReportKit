import Foundation

public struct CarbIntake: Hashable, Codable, Sendable {
    public var date: Date
    public var grams: Double
    public var absorptionTime: TimeInterval?
    public var fatGrams: Double?
    public var proteinGrams: Double?
    /// Carb equivalents generated from fat/protein (Trio "FPU" entries).
    /// Reported separately and excluded from carb totals so they are not counted twice.
    public var isFatProteinEquivalent: Bool
    public var sourceID: String?

    public init(
        date: Date,
        grams: Double,
        absorptionTime: TimeInterval? = nil,
        fatGrams: Double? = nil,
        proteinGrams: Double? = nil,
        isFatProteinEquivalent: Bool = false,
        sourceID: String? = nil
    ) {
        self.date = date
        self.grams = grams
        self.absorptionTime = absorptionTime
        self.fatGrams = fatGrams
        self.proteinGrams = proteinGrams
        self.isFatProteinEquivalent = isFatProteinEquivalent
        self.sourceID = sourceID
    }
}
