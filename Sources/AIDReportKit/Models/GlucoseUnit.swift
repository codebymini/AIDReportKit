import Foundation

/// Display unit for glucose. Every value inside the package is mg/dL;
/// conversion happens only at the edges (adapters and renderers).
public enum GlucoseUnit: String, Codable, Sendable, CaseIterable {
    case mgdL = "mg/dL"
    case mmolL = "mmol/L"

    /// mg/dL per mmol/L, from the molar mass of glucose HealthKit uses
    /// (`HKUnitMolarMassBloodGlucose`, 180.15588 g/mol), so values convert exactly as in
    /// Loop and LoopKit. Trio (× 0.0555) and LoopFollow agree to the printed decimal.
    public static let mgdLPerMmolL = 18.015588

    public func fromMgdL(_ value: Double) -> Double {
        self == .mgdL ? value : value / Self.mgdLPerMmolL
    }

    public func toMgdL(_ value: Double) -> Double {
        self == .mgdL ? value : value * Self.mgdLPerMmolL
    }

    /// Formats an mg/dL value in this unit: whole numbers for mg/dL, one decimal for mmol/L.
    public func format(mgdL value: Double, includeUnit: Bool = false) -> String {
        let converted = fromMgdL(value)
        let number = self == .mgdL ? String(format: "%.0f", converted) : String(format: "%.1f", converted)
        return includeUnit ? "\(number) \(rawValue)" : number
    }
}
