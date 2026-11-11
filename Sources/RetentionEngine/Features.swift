import Foundation

/// The total order facts are merged by: Apple's `signedDate`, then the notification UUID.
///
/// `(signedDate, notificationUUID)` is unique per notification, so equal clocks mean the same
/// notification delivered twice — which carries equal values, so keeping either is correct.
public struct FactClock: Codable, Sendable, Hashable, Comparable {
    public let signedDate: Int64
    public let tieBreaker: String

    public init(signedDate: Int64, tieBreaker: String) {
        self.signedDate = signedDate
        self.tieBreaker = tieBreaker
    }

    public static func < (lhs: FactClock, rhs: FactClock) -> Bool {
        if lhs.signedDate != rhs.signedDate { return lhs.signedDate < rhs.signedDate }
        return lhs.tieBreaker < rhs.tieBreaker
    }
}

/// A last-writer-wins register.
public struct LWW<Value: Codable & Sendable & Hashable>: Codable, Sendable, Hashable {
    public private(set) var value: Value
    public private(set) var clock: FactClock

    public init(_ value: Value, at clock: FactClock) {
        self.value = value
        self.clock = clock
    }

    mutating func merge(_ other: LWW<Value>) {
        if other.clock > clock {
            value = other.value
            clock = other.clock
        }
    }

    static func merged(_ lhs: LWW<Value>?, _ rhs: LWW<Value>?) -> LWW<Value>? {
        guard var result = lhs else { return rhs }
        if let rhs { result.merge(rhs) }
        return result
    }
}

/// One fact about a subscription, derived from an App Store Server Notification V2
/// (or, client-side, from a StoreKit transaction).
public struct SubscriptionFact: Codable, Sendable, Hashable {
    public enum Kind: Codable, Sendable, Hashable {
        case subscribed(purchaseDate: Int64, inIntroOffer: Bool)
        case renewed(inIntroOffer: Bool)
        case autoRenewChanged(enabled: Bool)
        case offerRedeemed(offerId: String)
        case renewalPreferenceChanged(productId: String)
        case billingRetryStarted
        case billingRecovered
        case expired
    }

    public let notificationUUID: String
    public let signedDate: Int64
    public let originalTransactionId: String
    public let productId: String?
    public let kind: Kind

    public init(
        notificationUUID: String,
        signedDate: Int64,
        originalTransactionId: String,
        productId: String?,
        kind: Kind
    ) {
        self.notificationUUID = notificationUUID
        self.signedDate = signedDate
        self.originalTransactionId = originalTransactionId
        self.productId = productId
        self.kind = kind
    }

    public var clock: FactClock { FactClock(signedDate: signedDate, tieBreaker: notificationUUID) }
}

/// The fields of a verified, decoded App Store Server Notification V2 that the store needs.
/// Decoding and verifying the notification itself is the host's job (Apple's server library).
public struct NotificationSummary: Sendable, Hashable, Codable {
    public let notificationType: String
    public let subtype: String?
    public let notificationUUID: String
    public let signedDate: Int64
    public let originalTransactionId: String
    public let productId: String?
    public let purchaseDate: Int64?
    /// The transaction's `offerType`: 1 introductory, 2 promotional, 3 offer code, 4 win-back.
    public let offerType: Int?
    public let offerIdentifier: String?
    /// The renewal info's `autoRenewProductId`, for renewal-preference changes.
    public let autoRenewProductId: String?

    public init(
        notificationType: String,
        subtype: String? = nil,
        notificationUUID: String,
        signedDate: Int64,
        originalTransactionId: String,
        productId: String? = nil,
        purchaseDate: Int64? = nil,
        offerType: Int? = nil,
        offerIdentifier: String? = nil,
        autoRenewProductId: String? = nil
    ) {
        self.notificationType = notificationType
        self.subtype = subtype
        self.notificationUUID = notificationUUID
        self.signedDate = signedDate
        self.originalTransactionId = originalTransactionId
        self.productId = productId
        self.purchaseDate = purchaseDate
        self.offerType = offerType
        self.offerIdentifier = offerIdentifier
        self.autoRenewProductId = autoRenewProductId
    }
}

public extension SubscriptionFact {
    /// Maps a notification to the fact the decision store cares about, or `nil` if it carries none.
    init?(_ notification: NotificationSummary) {
        let kind: Kind
        let isIntro = notification.offerType == 1
        switch (notification.notificationType, notification.subtype) {
        case ("SUBSCRIBED", _):
            kind = .subscribed(purchaseDate: notification.purchaseDate ?? notification.signedDate, inIntroOffer: isIntro)
        case ("DID_RENEW", "BILLING_RECOVERY"):
            kind = .billingRecovered
        case ("DID_RENEW", _):
            kind = .renewed(inIntroOffer: isIntro)
        case ("DID_CHANGE_RENEWAL_STATUS", "AUTO_RENEW_ENABLED"):
            kind = .autoRenewChanged(enabled: true)
        case ("DID_CHANGE_RENEWAL_STATUS", "AUTO_RENEW_DISABLED"):
            kind = .autoRenewChanged(enabled: false)
        case ("OFFER_REDEEMED", _):
            guard notification.offerType == 2, let offerId = notification.offerIdentifier else { return nil }
            kind = .offerRedeemed(offerId: offerId)
        case ("DID_CHANGE_RENEWAL_PREF", _):
            guard let target = notification.autoRenewProductId else { return nil }
            kind = .renewalPreferenceChanged(productId: target)
        case ("DID_FAIL_TO_RENEW", _):
            kind = .billingRetryStarted
        case ("EXPIRED", _), ("GRACE_PERIOD_EXPIRED", _), ("REFUND", _), ("REVOKE", _):
            kind = .expired
        default:
            return nil
        }
        self.init(
            notificationUUID: notification.notificationUUID,
            signedDate: notification.signedDate,
            originalTransactionId: notification.originalTransactionId,
            productId: notification.productId,
            kind: kind
        )
    }
}

/// A coarse lifecycle segment, evaluated at request time from precomputed features.
public enum Segment: String, Codable, Sendable, Hashable, CaseIterable {
    case trial
    case billingRetry
    case new
    case established
    case loyal
}

/// Tenure thresholds for segmenting, in milliseconds of paid tenure.
public struct SegmentThresholds: Codable, Sendable, Hashable {
    public let establishedAfterMilliseconds: Int64
    public let loyalAfterMilliseconds: Int64

    public static let `default` = SegmentThresholds(
        establishedAfterMilliseconds: 90 * 86_400_000,
        loyalAfterMilliseconds: 365 * 86_400_000
    )

    public init(establishedAfterMilliseconds: Int64, loyalAfterMilliseconds: Int64) {
        let established = max(0, establishedAfterMilliseconds)
        self.establishedAfterMilliseconds = established
        self.loyalAfterMilliseconds = max(established, loyalAfterMilliseconds)
    }

    private enum CodingKeys: String, CodingKey { case establishedAfterMilliseconds, loyalAfterMilliseconds }

    /// Decoding goes through the clamping initializer: a configuration file cannot set what code cannot.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            establishedAfterMilliseconds: try container.decode(Int64.self, forKey: .establishedAfterMilliseconds),
            loyalAfterMilliseconds: try container.decode(Int64.self, forKey: .loyalAfterMilliseconds)
        )
    }
}

/// One promotional-offer redemption.
public struct Redemption: Codable, Sendable, Hashable, Comparable {
    public let date: Int64
    public let offerId: String

    public init(date: Int64, offerId: String) {
        self.date = date
        self.offerId = offerId
    }

    public static func < (lhs: Redemption, rhs: Redemption) -> Bool {
        if lhs.date != rhs.date { return lhs.date < rhs.date }
        return lhs.offerId < rhs.offerId
    }
}

/// Everything the hot path knows about one subscriber, folded from facts.
///
/// The fold is a join: per-field last-writer-wins registers, a minimum, and a bounded
/// most-recent set. Each is commutative, associative and idempotent, so the result does not
/// depend on the order notifications arrive in or on how many times Apple retries them —
/// there is no "apply in order" step to get wrong and no seen-UUID set that grows forever.
public struct SubscriberFeatures: Codable, Sendable, Hashable {
    /// Redemption history kept per subscriber. Bounds memory; frequency caps are clamped to it.
    public static let redemptionHistoryLimit = 8

    public let originalTransactionId: String
    public private(set) var productId: LWW<String>?
    public private(set) var isActive: LWW<Bool>?
    public private(set) var autoRenewEnabled: LWW<Bool>?
    public private(set) var inIntroOffer: LWW<Bool>?
    public private(set) var inBillingRetry: LWW<Bool>?
    public private(set) var firstPurchaseDate: Int64?
    /// Most recent first, unique, at most `redemptionHistoryLimit` entries.
    public private(set) var redemptions: [Redemption] = []

    public init(originalTransactionId: String) {
        self.originalTransactionId = originalTransactionId
    }

    private enum CodingKeys: String, CodingKey {
        case originalTransactionId, productId, isActive, autoRenewEnabled, inIntroOffer, inBillingRetry, firstPurchaseDate, redemptions
    }

    /// Decoding re-applies the invariants: a record from another writer (an L2 cache, an older
    /// version, a hand-edited fixture) cannot bring unsorted, duplicate or overlong redemption
    /// history into the cool-down check.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(originalTransactionId: try container.decode(String.self, forKey: .originalTransactionId))
        productId = try container.decodeIfPresent(LWW<String>.self, forKey: .productId)
        isActive = try container.decodeIfPresent(LWW<Bool>.self, forKey: .isActive)
        autoRenewEnabled = try container.decodeIfPresent(LWW<Bool>.self, forKey: .autoRenewEnabled)
        inIntroOffer = try container.decodeIfPresent(LWW<Bool>.self, forKey: .inIntroOffer)
        inBillingRetry = try container.decodeIfPresent(LWW<Bool>.self, forKey: .inBillingRetry)
        firstPurchaseDate = try container.decodeIfPresent(Int64.self, forKey: .firstPurchaseDate)
        for redemption in try container.decodeIfPresent([Redemption].self, forKey: .redemptions) ?? [] {
            insertRedemption(redemption)
        }
    }

    /// Folds one fact in. Facts for other subscribers are ignored.
    public mutating func merge(_ fact: SubscriptionFact) {
        guard fact.originalTransactionId == originalTransactionId else { return }
        let clock = fact.clock
        func set<V: Codable & Sendable & Hashable>(_ keyPath: WritableKeyPath<SubscriberFeatures, LWW<V>?>, _ value: V) {
            self[keyPath: keyPath] = LWW.merged(self[keyPath: keyPath], LWW(value, at: clock))
        }
        if let productId = fact.productId { set(\.productId, productId) }
        switch fact.kind {
        case .subscribed(let purchaseDate, let intro):
            set(\.isActive, true)
            set(\.autoRenewEnabled, true)
            set(\.inIntroOffer, intro)
            set(\.inBillingRetry, false)
            firstPurchaseDate = min(firstPurchaseDate ?? purchaseDate, purchaseDate)
        case .renewed(let intro):
            set(\.isActive, true)
            set(\.inIntroOffer, intro)
            set(\.inBillingRetry, false)
        case .autoRenewChanged(let enabled):
            set(\.autoRenewEnabled, enabled)
        case .offerRedeemed(let offerId):
            set(\.isActive, true)
            insertRedemption(Redemption(date: fact.signedDate, offerId: offerId))
        case .renewalPreferenceChanged:
            break  // Attribution evidence only; it does not change what the hot path decides.
        case .billingRetryStarted:
            set(\.inBillingRetry, true)
        case .billingRecovered:
            set(\.isActive, true)
            set(\.inBillingRetry, false)
        case .expired:
            set(\.isActive, false)
            set(\.inBillingRetry, false)
        }
    }

    /// Joins another state for the same subscriber (for example an L2 result warming L1).
    public mutating func merge(_ other: SubscriberFeatures) {
        guard other.originalTransactionId == originalTransactionId else { return }
        productId = LWW.merged(productId, other.productId)
        isActive = LWW.merged(isActive, other.isActive)
        autoRenewEnabled = LWW.merged(autoRenewEnabled, other.autoRenewEnabled)
        inIntroOffer = LWW.merged(inIntroOffer, other.inIntroOffer)
        inBillingRetry = LWW.merged(inBillingRetry, other.inBillingRetry)
        if let date = other.firstPurchaseDate {
            firstPurchaseDate = min(firstPurchaseDate ?? date, date)
        }
        for redemption in other.redemptions { insertRedemption(redemption) }
    }

    private mutating func insertRedemption(_ redemption: Redemption) {
        guard !redemptions.contains(redemption) else { return }
        redemptions.append(redemption)
        redemptions.sort(by: >)
        if redemptions.count > Self.redemptionHistoryLimit {
            redemptions.removeLast(redemptions.count - Self.redemptionHistoryLimit)
        }
    }

    /// The segment at `now` (Apple's `signedDate` of the request). Tenure is evaluated here,
    /// not precomputed, because it changes with time even when no notification arrives.
    public func segment(at now: Int64, thresholds: SegmentThresholds = .default) -> Segment {
        if inBillingRetry?.value == true { return .billingRetry }
        if inIntroOffer?.value == true { return .trial }
        guard let firstPurchaseDate else { return .new }
        let tenure = Saturating.subtract(now, firstPurchaseDate)
        if tenure >= thresholds.loyalAfterMilliseconds { return .loyal }
        if tenure >= thresholds.establishedAfterMilliseconds { return .established }
        return .new
    }
}
