import Foundation

/// Why a subscriber may not be offered a promotional offer right now.
public enum OfferIneligibility: Codable, Sendable, Hashable {
    case inactive
    case introOffer
    case billingRetry
    case coolDown(remainingMilliseconds: Int64)
    case frequencyCap(redemptionsInWindow: Int)
}

/// Offer eligibility. Mirror whatever eligibility and "wait time between offers" you configure for
/// the offer in App Store Connect; the engine enforces it so an ineligible subscriber gets a
/// message that makes sense instead of an offer Apple would refuse to redeem.
public struct OfferPolicy: Codable, Sendable, Hashable {
    /// Minimum time since the last promotional-offer redemption.
    public let coolDownMilliseconds: Int64
    /// Maximum redemptions inside `windowMilliseconds`, clamped to the stored history length.
    public let maxRedemptionsInWindow: Int
    public let windowMilliseconds: Int64
    public let allowDuringIntroOffer: Bool
    public let allowDuringBillingRetry: Bool

    public init(
        coolDownMilliseconds: Int64,
        maxRedemptionsInWindow: Int,
        windowMilliseconds: Int64,
        allowDuringIntroOffer: Bool = false,
        allowDuringBillingRetry: Bool = false
    ) {
        self.coolDownMilliseconds = max(0, coolDownMilliseconds)
        // A cap larger than the history the store keeps could never be reached; clamp it so the
        // policy cannot silently become "unlimited".
        self.maxRedemptionsInWindow = min(max(0, maxRedemptionsInWindow), SubscriberFeatures.redemptionHistoryLimit)
        self.windowMilliseconds = max(0, windowMilliseconds)
        self.allowDuringIntroOffer = allowDuringIntroOffer
        self.allowDuringBillingRetry = allowDuringBillingRetry
    }

    private enum CodingKeys: String, CodingKey {
        case coolDownMilliseconds, maxRedemptionsInWindow, windowMilliseconds, allowDuringIntroOffer, allowDuringBillingRetry
    }

    /// Decoding goes through the clamping initializer: a configuration file cannot set what code cannot.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            coolDownMilliseconds: try container.decode(Int64.self, forKey: .coolDownMilliseconds),
            maxRedemptionsInWindow: try container.decode(Int.self, forKey: .maxRedemptionsInWindow),
            windowMilliseconds: try container.decode(Int64.self, forKey: .windowMilliseconds),
            allowDuringIntroOffer: try container.decode(Bool.self, forKey: .allowDuringIntroOffer),
            allowDuringBillingRetry: try container.decode(Bool.self, forKey: .allowDuringBillingRetry)
        )
    }

    public static let `default` = OfferPolicy(
        coolDownMilliseconds: 60 * 86_400_000,
        maxRedemptionsInWindow: 2,
        windowMilliseconds: 365 * 86_400_000
    )

    /// `nil` when eligible.
    public func ineligibility(of features: SubscriberFeatures, at now: Int64) -> OfferIneligibility? {
        if features.isActive?.value == false { return .inactive }
        if !allowDuringIntroOffer, features.inIntroOffer?.value == true { return .introOffer }
        if !allowDuringBillingRetry, features.inBillingRetry?.value == true { return .billingRetry }
        if let last = features.redemptions.first {
            // A redemption dated after the request (signing skew) counts as "just now".
            let elapsed = max(0, Saturating.subtract(now, last.date))
            if elapsed < coolDownMilliseconds {
                return .coolDown(remainingMilliseconds: Saturating.subtract(coolDownMilliseconds, elapsed))
            }
        }
        let windowStart = Saturating.subtract(now, windowMilliseconds)
        let recent = features.redemptions.filter { $0.date > windowStart }.count
        if recent >= maxRedemptionsInWindow { return .frequencyCap(redemptionsInWindow: recent) }
        return nil
    }
}
