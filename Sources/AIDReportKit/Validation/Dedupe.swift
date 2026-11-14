import Foundation

/// Shared duplicate detection, used by both validation rules (to report) and the sanitizer (to drop).
enum Dedupe {
    /// Splits `items` into kept and duplicate records. A record is a duplicate when its non-nil
    /// `sourceID` was already seen, or when an already-kept record lies less than `window` earlier
    /// and `isSame` says they match.
    static func split<T>(
        _ items: [T],
        date: (T) -> Date,
        sourceID: (T) -> String?,
        window: TimeInterval,
        isSame: (T, T) -> Bool
    ) -> (kept: [T], duplicates: [T]) {
        var kept: [T] = []
        var duplicates: [T] = []
        var seenIDs = Set<String>()
        for item in items.sorted(by: { date($0) < date($1) }) {
            if let id = sourceID(item), seenIDs.contains(id) {
                duplicates.append(item)
                continue
            }
            let itemDate = date(item)
            let isDuplicate = kept.reversed()
                .prefix { itemDate.timeIntervalSince(date($0)) < window }
                .contains { isSame($0, item) }
            if isDuplicate {
                duplicates.append(item)
            } else {
                kept.append(item)
                if let id = sourceID(item) { seenIDs.insert(id) }
            }
        }
        return (kept, duplicates)
    }

    static func glucose(_ readings: [GlucoseReading], window: TimeInterval) -> (kept: [GlucoseReading], duplicates: [GlucoseReading]) {
        split(readings, date: \.date, sourceID: \.sourceID, window: window) {
            $0.kind == $1.kind && abs($0.mgdL - $1.mgdL) < 1
        }
    }

    static func boluses(_ doses: [InsulinDose], window: TimeInterval) -> (kept: [InsulinDose], duplicates: [InsulinDose]) {
        split(doses, date: \.start, sourceID: \.sourceID, window: window) {
            abs($0.units - $1.units) < 0.01
        }
    }

    static func carbs(_ entries: [CarbIntake], window: TimeInterval) -> (kept: [CarbIntake], duplicates: [CarbIntake]) {
        split(entries, date: \.date, sourceID: \.sourceID, window: window) {
            $0.isFatProteinEquivalent == $1.isFatProteinEquivalent && abs($0.grams - $1.grams) < 0.5
        }
    }
}
