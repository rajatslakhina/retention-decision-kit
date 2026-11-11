import Foundation

/// A lock-protected value.
///
/// Every critical section is short and synchronous: nothing inside `withLock` may
/// suspend, which is what makes a plain `NSLock` safe to use from async code.
/// The hot path never waits behind a writer for longer than one critical section.
public final class Locked<Value>: @unchecked Sendable {
    // @unchecked Sendable: `value` is only read or written while `lock` is held.
    private let lock = NSLock()
    private var value: Value

    public init(_ value: Value) {
        self.value = value
    }

    @discardableResult
    public func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

/// Saturating arithmetic for values that arrive from outside the process.
///
/// `signedDate` comes from a signed request, policy windows come from humans, and
/// durations come from configuration. None of them is trusted to keep `+`, `-` or `*`
/// inside the integer range, and an overflow trap inside a request handler is an outage.
public enum Saturating {
    @inlinable
    public static func add<T: FixedWidthInteger & SignedInteger>(_ a: T, _ b: T) -> T {
        let (result, overflow) = a.addingReportingOverflow(b)
        guard overflow else { return result }
        return b > 0 ? .max : .min
    }

    @inlinable
    public static func subtract<T: FixedWidthInteger & SignedInteger>(_ a: T, _ b: T) -> T {
        let (result, overflow) = a.subtractingReportingOverflow(b)
        guard overflow else { return result }
        return b < 0 ? .max : .min
    }

    @inlinable
    public static func multiply<T: FixedWidthInteger & SignedInteger>(_ a: T, _ b: T) -> T {
        let (result, overflow) = a.multipliedReportingOverflow(by: b)
        guard overflow else { return result }
        return (a < 0) != (b < 0) ? .min : .max
    }

    /// Converts a `Double` to `Int64` without trapping: NaN maps to 0 and out-of-range values clamp.
    ///
    /// `Int64(Double)` traps on NaN, infinity and anything outside the representable range,
    /// and `Double(Int64.max)` rounds *up* past `Int64.max`, so the bounds are checked first.
    public static func int64(_ value: Double) -> Int64 {
        guard value.isFinite else { return value.isNaN ? 0 : (value > 0 ? .max : .min) }
        if value >= 9.223_372_036_854_775e18 { return .max }
        if value <= -9.223_372_036_854_775e18 { return .min }
        return Int64(value)
    }

    /// Converts a `Double` to `Int` using the platform's own `Int` range (32-bit on watchOS).
    public static func int(_ value: Double) -> Int {
        let wide = int64(value)
        if wide > Int64(Int.max) { return .max }
        if wide < Int64(Int.min) { return .min }
        return Int(wide)
    }

    /// The largest magnitude whose `components` fit `Int64` seconds with room to spare.
    /// (`Duration.components` traps beyond `Int64.max` seconds.)
    static let componentsLimit: Duration = .seconds(Int64.max / 2)

    static func clampedForComponents(_ duration: Duration) -> Duration {
        min(max(duration, .zero - componentsLimit), componentsLimit)
    }

    /// A `Duration` expressed in whole microseconds, saturating instead of trapping.
    public static func microseconds(_ duration: Duration) -> Int64 {
        let parts = clampedForComponents(duration).components
        let whole = multiply(parts.seconds, 1_000_000)
        return add(whole, parts.attoseconds / 1_000_000_000_000)
    }

    /// A `Duration` expressed in whole milliseconds, saturating instead of trapping.
    public static func milliseconds(_ duration: Duration) -> Int64 {
        let parts = clampedForComponents(duration).components
        let whole = multiply(parts.seconds, 1_000)
        return add(whole, parts.attoseconds / 1_000_000_000_000_000)
    }
}

/// Stable, process-independent hashing.
///
/// Swift's `Hasher` is randomly seeded per process, so it must never decide anything
/// that has to agree across processes or restarts — experiment buckets, shard routing
/// or content identifiers. FNV-1a is not cryptographic; it is used here only for
/// bucketing and for identifiers derived from our own copy, never for security.
public enum StableHash {
    public static let fnvOffsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
    public static let fnvPrime: UInt64 = 0x0000_0100_0000_01b3

    public static func fnv1a64<Bytes: Sequence>(_ bytes: Bytes) -> UInt64 where Bytes.Element == UInt8 {
        var hash = fnvOffsetBasis
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* fnvPrime
        }
        return hash
    }

    public static func fnv1a64(_ string: String) -> UInt64 {
        fnv1a64(string.utf8)
    }

    /// An RFC 9562 version-8 UUID derived from `content`.
    ///
    /// Apple's Upload Message endpoint is not idempotent (re-uploading an identifier returns
    /// `MessageAlreadyExistsError`). Deriving the identifier from the copy makes a re-run of the
    /// offline pipeline safe: the same text always maps to the same identifier.
    public static func contentUUID(_ content: String) -> String {
        let high = fnv1a64("uuid.high\u{0}" + content)
        let low = fnv1a64("uuid.low\u{0}" + content)
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<8 {
            bytes[index] = UInt8(truncatingIfNeeded: high >> UInt64(56 - index * 8))
            bytes[index + 8] = UInt8(truncatingIfNeeded: low >> UInt64(56 - index * 8))
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x80  // version 8
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 9562 variant
        let hex = bytes.map { byte -> String in
            let digits = String(byte, radix: 16)
            return digits.count == 1 ? "0" + digits : digits
        }.joined()
        let characters = Array(hex)
        func slice(_ range: Range<Int>) -> String { String(characters[range]) }
        return [slice(0..<8), slice(8..<12), slice(12..<16), slice(16..<20), slice(20..<32)]
            .joined(separator: "-")
    }
}

/// Confidence intervals for proportions, shared by the variant ranker and the experiment readout.
public enum Wilson {
    /// The Wilson score interval for `successes` out of `trials`; `nil` when there are no trials.
    public static func interval(successes: Int, trials: Int, z: Double = 1.96) -> ClosedRange<Double>? {
        guard trials > 0, z.isFinite, z > 0 else { return nil }
        let clampedSuccesses = min(max(successes, 0), trials)
        let n = Double(trials)
        let p = Double(clampedSuccesses) / n
        let z2 = z * z
        let denominator = 1 + z2 / n
        let center = (p + z2 / (2 * n)) / denominator
        let margin = z * ((p * (1 - p) / n + z2 / (4 * n * n)).squareRoot()) / denominator
        let lower = max(0, center - margin)
        let upper = min(1, center + margin)
        return lower...upper
    }

    /// Newcombe's hybrid score interval (method 10) for the difference `p1 - p2`.
    public static func differenceInterval(
        successes1: Int, trials1: Int,
        successes2: Int, trials2: Int,
        z: Double = 1.96
    ) -> (estimate: Double, interval: ClosedRange<Double>)? {
        guard
            let first = interval(successes: successes1, trials: trials1, z: z),
            let second = interval(successes: successes2, trials: trials2, z: z)
        else { return nil }
        let p1 = Double(min(max(successes1, 0), trials1)) / Double(trials1)
        let p2 = Double(min(max(successes2, 0), trials2)) / Double(trials2)
        let estimate = p1 - p2
        let lowerSpread = ((p1 - first.lowerBound) * (p1 - first.lowerBound)
            + (second.upperBound - p2) * (second.upperBound - p2)).squareRoot()
        let upperSpread = ((first.upperBound - p1) * (first.upperBound - p1)
            + (p2 - second.lowerBound) * (p2 - second.lowerBound)).squareRoot()
        let lower = max(-1, estimate - lowerSpread)
        let upper = min(1, estimate + upperSpread)
        return (estimate, lower...upper)
    }
}
