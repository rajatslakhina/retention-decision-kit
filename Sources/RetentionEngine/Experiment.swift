import Foundation

/// Which side of the experiment a subscriber is on.
public enum Arm: String, Codable, Sendable, Hashable, CaseIterable {
    /// Gets the personalized decision.
    case treatment
    /// Gets the product's control message, so the save rate of the personalized path is measurable.
    case holdout
}

/// Deterministic experiment assignment.
///
/// Assignment is a pure function of `(salt, originalTransactionId)`: the same subscriber lands in
/// the same arm on every request, every server and every deploy, with no lookup and no state.
/// It runs *before* any feature lookup, so the comparison is intent-to-treat — a treatment
/// subscriber whose lookup timed out is still counted in treatment.
public struct ExperimentAssigner: Sendable, Hashable, Codable {
    /// Basis points: 10_000 buckets, so holdout shares are expressible to 0.01%.
    public static let bucketCount = 10_000

    /// Change the salt to start a new experiment; never reuse one, or old assignments leak in.
    public let salt: String
    /// Share of subscribers held out, in basis points, clamped to `0...10_000`.
    public let holdoutBasisPoints: Int

    public init(salt: String, holdoutBasisPoints: Int) {
        self.salt = salt
        self.holdoutBasisPoints = min(max(holdoutBasisPoints, 0), Self.bucketCount)
    }

    private enum CodingKeys: String, CodingKey { case salt, holdoutBasisPoints }

    /// Decoding goes through the clamping initializer: a configuration file cannot set what code cannot.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            salt: try container.decode(String.self, forKey: .salt),
            holdoutBasisPoints: try container.decode(Int.self, forKey: .holdoutBasisPoints)
        )
    }

    /// A bucket in `0..<10_000`, stable across processes (FNV-1a, not `Hasher`).
    public func bucket(for originalTransactionId: String) -> Int {
        let hash = StableHash.fnv1a64(salt + ":" + originalTransactionId)
        // The remainder is < 10_000, so the conversion fits `Int` on every platform.
        return Int(hash % UInt64(Self.bucketCount))
    }

    public func arm(for originalTransactionId: String) -> Arm {
        bucket(for: originalTransactionId) < holdoutBasisPoints ? .holdout : .treatment
    }
}
