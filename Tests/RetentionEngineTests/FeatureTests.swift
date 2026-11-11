import XCTest
@testable import RetentionEngine

/// The broken alternative: apply facts in arrival order, each one overwriting the record.
struct ArrivalOrderFeatures: Equatable {
    var autoRenew: Bool?
    var inBillingRetry: Bool?
    var active: Bool?

    mutating func apply(_ fact: SubscriptionFact) {
        switch fact.kind {
        case .autoRenewChanged(let enabled): autoRenew = enabled
        case .billingRetryStarted: inBillingRetry = true
        case .billingRecovered: inBillingRetry = false; active = true
        case .subscribed: autoRenew = true; active = true; inBillingRetry = false
        case .renewed: active = true; inBillingRetry = false
        case .expired: active = false
        case .offerRedeemed, .renewalPreferenceChanged: break
        }
    }
}

/// Checks a fold for order independence over every permutation of `facts`.
func isOrderIndependent<State: Equatable>(_ facts: [SubscriptionFact], initial: State, fold: (inout State, SubscriptionFact) -> Void) -> Bool {
    var reference: State?
    func permute(_ prefix: [SubscriptionFact], _ rest: [SubscriptionFact]) -> Bool {
        if rest.isEmpty {
            var state = initial
            for fact in prefix { fold(&state, fact) }
            if let reference { return reference == state }
            reference = state
            return true
        }
        for index in rest.indices {
            var remaining = rest
            let next = remaining.remove(at: index)
            if !permute(prefix + [next], remaining) { return false }
        }
        return true
    }
    return permute([], facts)
}

final class FeatureTests: XCTestCase {
    let id = "sub-1"

    var history: [SubscriptionFact] {
        [
            Fixture.subscribed(id, daysAgo: 400),
            SubscriptionFact(notificationUUID: "n2", signedDate: Fixture.now - 30 * Fixture.day, originalTransactionId: id, productId: Fixture.product, kind: .offerRedeemed(offerId: "o1")),
            SubscriptionFact(notificationUUID: "n3", signedDate: Fixture.now - 3 * Fixture.day, originalTransactionId: id, productId: nil, kind: .billingRetryStarted),
            SubscriptionFact(notificationUUID: "n4", signedDate: Fixture.now - 2 * Fixture.day, originalTransactionId: id, productId: nil, kind: .billingRecovered),
            SubscriptionFact(notificationUUID: "n5", signedDate: Fixture.now - 1 * Fixture.day, originalTransactionId: id, productId: nil, kind: .autoRenewChanged(enabled: false)),
            SubscriptionFact(notificationUUID: "n6", signedDate: Fixture.now - 1 * Fixture.day + 1, originalTransactionId: id, productId: nil, kind: .autoRenewChanged(enabled: true)),
        ]
    }

    func testMergeIsOrderIndependentAcrossAllPermutations() {
        let independent = isOrderIndependent(history, initial: SubscriberFeatures(originalTransactionId: id)) { $0.merge($1) }
        XCTAssertTrue(independent, "720 orderings must fold to one state")
        var features = SubscriberFeatures(originalTransactionId: id)
        for fact in history { features.merge(fact) }
        XCTAssertEqual(features.autoRenewEnabled?.value, true)
        XCTAssertEqual(features.inBillingRetry?.value, false)
        XCTAssertEqual(features.isActive?.value, true)
        XCTAssertEqual(features.redemptions.map(\.offerId), ["o1"])
    }

    /// The same checker rejects the arrival-order fold — so the test above can fail.
    func testCheckerCatchesArrivalOrderFold() {
        XCTAssertFalse(isOrderIndependent(history, initial: ArrivalOrderFeatures()) { $0.apply($1) })
    }

    func testDuplicatesAreIdempotent() {
        var once = SubscriberFeatures(originalTransactionId: id)
        var thrice = SubscriberFeatures(originalTransactionId: id)
        for fact in history { once.merge(fact) }
        for fact in history + history + history.reversed() { thrice.merge(fact) }
        XCTAssertEqual(once, thrice)
    }

    func testStateJoinMatchesFactFold() {
        var left = SubscriberFeatures(originalTransactionId: id)
        var right = SubscriberFeatures(originalTransactionId: id)
        var all = SubscriberFeatures(originalTransactionId: id)
        for (index, fact) in history.enumerated() {
            if index.isMultiple(of: 2) { left.merge(fact) } else { right.merge(fact) }
            all.merge(fact)
        }
        left.merge(right)
        XCTAssertEqual(left, all)
    }

    func testRedemptionHistoryIsBoundedMostRecentFirst() {
        var features = SubscriberFeatures(originalTransactionId: id)
        for index in 0..<50 {
            features.merge(SubscriptionFact(notificationUUID: "r\(index)", signedDate: Int64(index), originalTransactionId: id, productId: nil, kind: .offerRedeemed(offerId: "o\(index)")))
        }
        XCTAssertEqual(features.redemptions.count, SubscriberFeatures.redemptionHistoryLimit)
        XCTAssertEqual(features.redemptions.first?.date, 49)
        XCTAssertEqual(features.redemptions.map(\.date), (42...49).reversed().map(Int64.init))
    }

    func testFactsForOtherSubscribersAreIgnored() {
        var features = SubscriberFeatures(originalTransactionId: id)
        features.merge(Fixture.subscribed("someone-else", daysAgo: 10))
        XCTAssertEqual(features, SubscriberFeatures(originalTransactionId: id))
    }

    /// Tenure runs from the first purchase: a resubscription does not reset it, in either arrival order.
    func testTenureStartsAtTheEarliestPurchase() {
        let original = Fixture.subscribed("t", daysAgo: 400)
        let resubscribed = Fixture.subscribed("t", daysAgo: 20)
        for facts in [[original, resubscribed], [resubscribed, original]] {
            var features = SubscriberFeatures(originalTransactionId: "t")
            for fact in facts { features.merge(fact) }
            XCTAssertEqual(features.firstPurchaseDate, Fixture.now - 400 * Fixture.day)
            XCTAssertEqual(features.segment(at: Fixture.now, thresholds: .default), .loyal)
        }
    }

    /// A record from another writer can't smuggle unsorted, duplicate or overlong history past the invariants.
    func testDecodingRestoresTheRedemptionInvariants() throws {
        let dates = [5, 1, 9, 3, 9, 7, 2, 8, 6, 4, 10].map { Int64($0) }
        let redemptions = dates.map { #"{"date":\#($0),"offerId":"o"}"# }.joined(separator: ",")
        let json = #"{"originalTransactionId":"r","redemptions":[\#(redemptions)]}"#
        let decoded = try JSONDecoder().decode(SubscriberFeatures.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.redemptions.map(\.date), [10, 9, 8, 7, 6, 5, 4, 3], "most recent first, unique, bounded")
        let roundTrip = try JSONDecoder().decode(SubscriberFeatures.self, from: try JSONEncoder().encode(decoded))
        XCTAssertEqual(roundTrip, decoded)
    }

    func testSegmentsAtRequestTime() {
        var loyal = SubscriberFeatures(originalTransactionId: "a")
        loyal.merge(Fixture.subscribed("a", daysAgo: 400))
        XCTAssertEqual(loyal.segment(at: Fixture.now), .loyal)
        XCTAssertEqual(loyal.segment(at: Fixture.now - 300 * Fixture.day), .established)
        XCTAssertEqual(loyal.segment(at: Fixture.now - 380 * Fixture.day), .new)
        // Extreme timestamps saturate instead of trapping.
        XCTAssertEqual(loyal.segment(at: .min), .new)
        XCTAssertEqual(loyal.segment(at: .max), .loyal)
        var trial = SubscriberFeatures(originalTransactionId: "b")
        trial.merge(Fixture.subscribed("b", daysAgo: 3, intro: true))
        XCTAssertEqual(trial.segment(at: Fixture.now), .trial)
        XCTAssertEqual(SubscriberFeatures(originalTransactionId: "c").segment(at: Fixture.now), .new)
    }

    func testNotificationMapping() {
        func fact(_ type: String, _ subtype: String? = nil, offerType: Int? = nil, offer: String? = nil, pref: String? = nil) -> SubscriptionFact.Kind? {
            SubscriptionFact(NotificationSummary(notificationType: type, subtype: subtype, notificationUUID: "u", signedDate: 1, originalTransactionId: "t", productId: "p", purchaseDate: 1, offerType: offerType, offerIdentifier: offer, autoRenewProductId: pref))?.kind
        }
        XCTAssertEqual(fact("SUBSCRIBED", "INITIAL_BUY", offerType: 1), .subscribed(purchaseDate: 1, inIntroOffer: true))
        XCTAssertEqual(fact("DID_RENEW", "BILLING_RECOVERY"), .billingRecovered)
        XCTAssertEqual(fact("DID_RENEW"), .renewed(inIntroOffer: false))
        XCTAssertEqual(fact("DID_CHANGE_RENEWAL_STATUS", "AUTO_RENEW_DISABLED"), .autoRenewChanged(enabled: false))
        XCTAssertEqual(fact("OFFER_REDEEMED", offerType: 2, offer: "o"), .offerRedeemed(offerId: "o"))
        XCTAssertNil(fact("OFFER_REDEEMED", offerType: 1, offer: "intro"), "only promotional offers count")
        XCTAssertEqual(fact("DID_CHANGE_RENEWAL_PREF", "DOWNGRADE", pref: "lite"), .renewalPreferenceChanged(productId: "lite"))
        XCTAssertEqual(fact("DID_FAIL_TO_RENEW", "GRACE_PERIOD"), .billingRetryStarted)
        XCTAssertEqual(fact("REFUND"), .expired)
        XCTAssertNil(fact("TEST"))
        XCTAssertNil(fact("DID_CHANGE_RENEWAL_STATUS", "SOMETHING_NEW"))
    }

    /// Concurrent writers and readers: the final store equals a sequential fold.
    func testConcurrentIngestionMatchesSequentialFold() async {
        let store = FeatureStore(shardCount: 8)
        let subscribers = (0..<40).map { "c\($0)" }
        var facts: [SubscriptionFact] = []
        for subscriber in subscribers {
            facts.append(Fixture.subscribed(subscriber, daysAgo: 200))
            for step in 0..<10 {
                facts.append(SubscriptionFact(notificationUUID: "\(subscriber)-\(step)", signedDate: Fixture.now - Int64(step) * 1_000, originalTransactionId: subscriber, productId: nil, kind: .autoRenewChanged(enabled: step.isMultiple(of: 2))))
            }
        }
        var generator = SplitMix64(seed: 7)
        let shuffled = facts.shuffled(using: &generator)
        let chunks = stride(from: 0, to: shuffled.count, by: 37).map { Array(shuffled[$0..<min($0 + 37, shuffled.count)]) }
        await withTaskGroup(of: Void.self) { group in
            for chunk in chunks {
                group.addTask { store.ingest(chunk) }
                group.addTask { for subscriber in subscribers { _ = store.features(for: subscriber) } }
            }
        }
        for subscriber in subscribers {
            var expected = SubscriberFeatures(originalTransactionId: subscriber)
            for fact in facts where fact.originalTransactionId == subscriber { expected.merge(fact) }
            XCTAssertEqual(store.features(for: subscriber), expected)
            XCTAssertEqual(store.features(for: subscriber)?.autoRenewEnabled?.value, true, "step 0 is the newest and enables auto-renew")
        }
        XCTAssertEqual(store.count, subscribers.count)
        XCTAssertEqual(FeatureStore(shardCount: 0).count, 0, "shard count clamps to at least one")
    }
}
