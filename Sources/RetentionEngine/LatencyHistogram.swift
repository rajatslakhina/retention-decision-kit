import Foundation

/// A fixed-memory latency histogram with three significant digits.
///
/// Values are tracked in microseconds: exactly below 1 ms, then in buckets whose width is at
/// most 1% of their lower bound, up to ~27.8 hours (larger values land in the last bucket).
/// Quantiles report the bucket's upper bound clamped to the true maximum, so a reported p99 is
/// never *below* the exact p99 and at most 1% above it. Memory is ~64 KB whatever the count, and
/// histograms from many workers merge exactly — which a reservoir of raw samples cannot do.
public struct LatencyHistogram: Sendable, Hashable {
    public static let maximumTrackableMicroseconds: Int64 = 99_999_999_999
    static let exactBelow: Int64 = 1_000
    static let bucketsPerDecade = 900
    static let bucketCount = 1_000 + 8 * 900
    private static let powersOfTen: [Int64] = (0...11).map { exponent in
        (0..<exponent).reduce(Int64(1)) { value, _ in value * 10 }
    }

    private var counts: [Int]
    public private(set) var count = 0
    public private(set) var minimumMicroseconds: Int64?
    public private(set) var maximumMicroseconds: Int64?
    private var sumMicroseconds: Int64 = 0

    public init() {
        counts = Array(repeating: 0, count: Self.bucketCount)
    }

    static func bucketIndex(forMicroseconds raw: Int64) -> Int {
        let value = min(max(raw, 0), maximumTrackableMicroseconds)
        if value < exactBelow { return Int(value) }
        var digits = 4
        while digits < 11, value >= powersOfTen[digits] { digits += 1 }
        let exponent = digits - 3                       // 1...8
        let mantissa = Int(value / powersOfTen[exponent]) // 100...999
        return 1_000 + (exponent - 1) * bucketsPerDecade + (mantissa - 100)
    }

    static func upperBoundMicroseconds(ofBucket index: Int) -> Int64 {
        let clamped = min(max(index, 0), bucketCount - 1)
        if clamped < 1_000 { return Int64(clamped) }
        let offset = clamped - 1_000
        let exponent = offset / bucketsPerDecade + 1
        let mantissa = Int64(offset % bucketsPerDecade + 100)
        return (mantissa + 1) * powersOfTen[exponent] - 1
    }

    public mutating func record(_ latency: Duration) {
        record(microseconds: Saturating.microseconds(latency))
    }

    public mutating func record(microseconds raw: Int64) {
        let value = min(max(raw, 0), Self.maximumTrackableMicroseconds)
        let index = Self.bucketIndex(forMicroseconds: value)
        counts[index] = Saturating.add(counts[index], 1)
        count = Saturating.add(count, 1)
        sumMicroseconds = Saturating.add(sumMicroseconds, value)
        minimumMicroseconds = min(minimumMicroseconds ?? value, value)
        maximumMicroseconds = max(maximumMicroseconds ?? value, value)
    }

    public mutating func merge(_ other: LatencyHistogram) {
        for index in counts.indices where other.counts[index] > 0 {
            counts[index] = Saturating.add(counts[index], other.counts[index])
        }
        count = Saturating.add(count, other.count)
        sumMicroseconds = Saturating.add(sumMicroseconds, other.sumMicroseconds)
        if let low = other.minimumMicroseconds { minimumMicroseconds = min(minimumMicroseconds ?? low, low) }
        if let high = other.maximumMicroseconds { maximumMicroseconds = max(maximumMicroseconds ?? high, high) }
    }

    /// The nearest-rank quantile; `nil` when empty or when `q` is not a finite value in `0...1`.
    public func quantile(_ q: Double) -> Duration? {
        guard count > 0, q.isFinite, q >= 0, q <= 1, let maximum = maximumMicroseconds else { return nil }
        let target = (q * Double(count)).rounded(.up)
        let rank = target >= Double(count) ? count : max(1, Saturating.int(target))
        var cumulative = 0
        for (index, bucketTotal) in counts.enumerated() where bucketTotal > 0 {
            cumulative = Saturating.add(cumulative, bucketTotal)
            if cumulative >= rank {
                return .microseconds(min(Self.upperBoundMicroseconds(ofBucket: index), maximum))
            }
        }
        return .microseconds(maximum)
    }

    /// The arithmetic mean. Shown next to p99 precisely because it hides the tail.
    public var mean: Duration? {
        guard count > 0 else { return nil }
        return .microseconds(sumMicroseconds / Int64(count))
    }

    /// Non-empty buckets as `(upper bound, count)`, for charts.
    public var nonEmptyBuckets: [(upperBound: Duration, count: Int)] {
        counts.indices.compactMap { index in
            counts[index] > 0 ? (.microseconds(Self.upperBoundMicroseconds(ofBucket: index)), counts[index]) : nil
        }
    }
}
