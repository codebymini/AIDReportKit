import Foundation

/// Glucose by time of day, all days overlaid: percentiles (the Ambulatory Glucose Profile) and
/// the share of readings in each range.
public struct AGPProfile: Hashable, Codable, Sendable {
    public struct Bucket: Hashable, Codable, Sendable {
        /// Minutes after local midnight where this bucket starts.
        public var startMinute: Int
        public var readingCount: Int
        /// `nil` when the bucket has no readings.
        public var percentiles: Percentiles?
        /// Share of this bucket's readings in each range; `nil` when the bucket has no readings.
        public var timeInRanges: TimeInRanges?
    }

    public var bucketMinutes: Int
    public var buckets: [Bucket]

    public static func compute(
        _ readings: [GlucoseReading],
        timeZone: TimeZone,
        bucketMinutes: Int = 60,
        thresholds: GlucoseThresholds = .consensus
    ) -> AGPProfile {
        let size = min(max(bucketMinutes, 5), 1440)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let bucketCount = Int((1440.0 / Double(size)).rounded(.up))
        var values = Array(repeating: [Double](), count: bucketCount)
        for reading in readings where reading.kind == .sensor {
            let parts = calendar.dateComponents([.hour, .minute], from: reading.date)
            let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            values[min(minute / size, bucketCount - 1)].append(reading.mgdL)
        }
        let buckets = values.enumerated().map { index, bucket in
            Bucket(
                startMinute: index * size,
                readingCount: bucket.count,
                percentiles: Percentiles(values: bucket),
                timeInRanges: bucket.isEmpty ? nil : TimeInRanges(values: bucket, thresholds: thresholds)
            )
        }
        return AGPProfile(bucketMinutes: size, buckets: buckets)
    }
}
