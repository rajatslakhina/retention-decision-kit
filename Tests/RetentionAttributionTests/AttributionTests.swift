import RetentionEngine
import XCTest
@testable import RetentionAttribution

final class AttributionTests: XCTestCase {
    let t0: Int64 = 1_794_268_800_000
    let policy = AttributionPolicy(windowMilliseconds: 3_600_000, clockSkewToleranceMilliseconds: 5_000)

    func record(_ id: String, subscriber: String = "s1", at time: Int64? = nil, arm: Arm = .treatment, offer: String? = nil, alternate: String? = nil, replay: Bool = false) -> DecisionRecord {
        DecisionRecord(
            decisionId: id, requestIdentifier: "req-\(id)", originalTransactionId: subscriber, productId: "pro", locale: "en-US",
            arm: arm, pathLabel: "personalized", isReplay: replay, messageIdentifier: "m", variantId: "v",
            offerId: offer, alternateProductId: alternate, decidedAt: time ?? t0, totalMicroseconds: 1, catalogVersion: "c"
        )
    }

    func fact(_ uuid: String, subscriber: String = "s1", after offset: Int64, _ kind: SubscriptionFact.Kind) -> SubscriptionFact {
        SubscriptionFact(notificationUUID: uuid, signedDate: t0 + offset, originalTransactionId: subscriber, productId: "pro", kind: kind)
    }

    func outcomes(_ decisions: [DecisionRecord], _ facts: [SubscriptionFact], asOf: Int64? = nil) -> [String: AttributedOutcome] {
        let result = AttributionEngine(policy: policy).attribute(decisions: decisions, facts: facts, asOf: asOf ?? t0 + 10_000_000)
        return Dictionary(uniqueKeysWithValues: result.map { ($0.record.decisionId, $0.outcome) })
    }

    func testOfferRedemptionMatchesOnlyTheServedOffer() {
        XCTAssertEqual(outcomes([record("d", offer: "o1")], [fact("f", after: 20_000, .offerRedeemed(offerId: "o1"))])["d"], .redeemedOffer)
        XCTAssertEqual(outcomes([record("d", offer: "o1")], [fact("f", after: 20_000, .offerRedeemed(offerId: "other"))])["d"], .retained)
    }

    func testPlanSwitch() {
        XCTAssertEqual(outcomes([record("d", alternate: "lite")], [fact("f", after: 1_000, .renewalPreferenceChanged(productId: "lite"))])["d"], .switchedPlan)
    }

    func testCancelReEnableAndExpiry() {
        XCTAssertEqual(outcomes([record("d")], [fact("f", after: 10_000, .autoRenewChanged(enabled: false))])["d"], .cancelled)
        XCTAssertEqual(outcomes([record("d")], [
            fact("f1", after: 10_000, .autoRenewChanged(enabled: false)),
            fact("f2", after: 50_000, .autoRenewChanged(enabled: true)),
        ])["d"], .retained, "changed their mind inside the window")
        XCTAssertEqual(outcomes([record("d")], [fact("f", after: 10_000, .expired)])["d"], .cancelled)
    }

    func testWindowBoundsAndSkew() {
        XCTAssertEqual(outcomes([record("d")], [fact("late", after: 3_600_000, .autoRenewChanged(enabled: false))])["d"], .retained, "the window is half-open")
        XCTAssertEqual(outcomes([record("d")], [fact("skewed", after: -4_000, .autoRenewChanged(enabled: false))])["d"], .cancelled, "within the skew tolerance")
        XCTAssertEqual(outcomes([record("d")], [fact("before", after: -6_000, .autoRenewChanged(enabled: false))])["d"], .retained)
    }

    func testPendingUntilTheWindowCloses() {
        XCTAssertEqual(outcomes([record("d")], [fact("f", after: 10_000, .autoRenewChanged(enabled: false))], asOf: t0 + 60_000)["d"], .pending)
        XCTAssertEqual(outcomes([record("d", offer: "o")], [fact("f", after: 10_000, .offerRedeemed(offerId: "o"))], asOf: t0 + 60_000)["d"], .redeemedOffer, "a redemption is final at once")
    }

    func testLastTouchWins() {
        let first = record("first", at: t0)
        let second = record("second", at: t0 + 600_000)
        let result = outcomes([first, second], [fact("cancel", after: 700_000, .autoRenewChanged(enabled: false))])
        XCTAssertEqual(result["first"], .retained, "its window ended when the second decision was made")
        XCTAssertEqual(result["second"], .cancelled)
        let simultaneous = outcomes([record("a", at: t0), record("b", at: t0)], [])
        XCTAssertEqual(simultaneous["a"], .superseded)
        XCTAssertEqual(simultaneous["b"], .retained)
    }

    func testReplaysAndDuplicatesAreIgnored() {
        let result = AttributionEngine(policy: policy).attribute(
            decisions: [record("d"), record("d"), record("d", replay: true)],
            facts: [fact("f", after: 1_000, .autoRenewChanged(enabled: false)), fact("f", after: 1_000, .autoRenewChanged(enabled: false))],
            asOf: t0 + 10_000_000
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.outcome, .cancelled)
    }

    /// The join depends only on the sets: shuffling and duplicating inputs never changes it.
    func testOrderAndDuplicationInvariance() {
        var decisions: [DecisionRecord] = []
        var facts: [SubscriptionFact] = []
        for index in 0..<30 {
            let subscriber = "s\(index % 7)"
            decisions.append(record("d\(index)", subscriber: subscriber, at: t0 + Int64(index) * 400_000, offer: index % 3 == 0 ? "o" : nil))
            if index % 2 == 0 { facts.append(fact("f\(index)", subscriber: subscriber, after: Int64(index) * 400_000 + 5_000, .autoRenewChanged(enabled: index % 4 == 0))) }
            if index % 3 == 0 { facts.append(fact("r\(index)", subscriber: subscriber, after: Int64(index) * 400_000 + 9_000, .offerRedeemed(offerId: "o"))) }
        }
        let reference = outcomes(decisions, facts)
        var generator = SplitMix64(seed: 42)
        for _ in 0..<20 {
            let shuffled = outcomes((decisions + decisions.prefix(5)).shuffled(using: &generator), (facts + facts).shuffled(using: &generator))
            XCTAssertEqual(shuffled, reference)
        }
    }

    func testReadoutIsPerSubscriberWithIntervals() throws {
        var attributions: [Attribution] = []
        func add(_ subscriber: String, _ arm: Arm, _ outcome: AttributedOutcome, decision: String = UUID().uuidString) {
            attributions.append(Attribution(record: record(decision, subscriber: subscriber, arm: arm), outcome: outcome, evidence: nil, windowStart: 0, windowEnd: 1))
        }
        for index in 0..<100 { add("t\(index)", .treatment, index < 20 ? .cancelled : .retained) }
        add("t0", .treatment, .retained)  // a second decision for the same subscriber does not add a subscriber
        for index in 0..<100 { add("h\(index)", .holdout, index < 30 ? .cancelled : .retained) }
        add("pending", .holdout, .pending)
        add("treat-redeem", .treatment, .redeemedOffer)
        let readout = ExperimentReadout.make(from: attributions)
        XCTAssertEqual(readout.treatment.resolvedSubscribers, 101)
        XCTAssertEqual(readout.treatment.cancelled, 20)
        XCTAssertEqual(readout.treatment.redeemedOffer, 1)
        XCTAssertEqual(readout.holdout.resolvedSubscribers, 100)
        XCTAssertEqual(readout.holdout.pendingSubscribers, 1)
        let prevented = try XCTUnwrap(readout.preventedCancellations)
        XCTAssertEqual(prevented.estimate, 0.30 - 20.0 / 101.0, accuracy: 1e-9)
        XCTAssertLessThan(prevented.lower, prevented.estimate)
        XCTAssertGreaterThan(prevented.upper, prevented.estimate)
        XCTAssertNotNil(readout.treatment.cancellationInterval)
    }

    /// The headline metric needs both arms: holdout decisions are attributed exactly like treatment ones.
    func testBothArmsAreAttributedAndCompared() throws {
        let decisions = [
            record("h1", subscriber: "h1", arm: .holdout), record("h2", subscriber: "h2", arm: .holdout), record("h3", subscriber: "h3", arm: .holdout),
            record("t1", subscriber: "t1", offer: "o"), record("t2", subscriber: "t2", offer: "o"), record("t3", subscriber: "t3", offer: "o"),
        ]
        let facts = [
            fact("h1-off", subscriber: "h1", after: 10_000, .autoRenewChanged(enabled: false)),
            fact("h2-off", subscriber: "h2", after: 10_000, .autoRenewChanged(enabled: false)),
            fact("t1-redeem", subscriber: "t1", after: 10_000, .offerRedeemed(offerId: "o")),
            fact("t3-off", subscriber: "t3", after: 10_000, .autoRenewChanged(enabled: false)),
        ]
        let attributed = AttributionEngine(policy: policy).attribute(decisions: decisions, facts: facts, asOf: t0 + 10_000_000)
        let byId = Dictionary(uniqueKeysWithValues: attributed.map { ($0.record.decisionId, $0.outcome) })
        XCTAssertEqual(byId, ["h1": .cancelled, "h2": .cancelled, "h3": .retained, "t1": .redeemedOffer, "t2": .retained, "t3": .cancelled])
        let readout = ExperimentReadout.make(from: attributed)
        XCTAssertEqual(readout.holdout.resolvedSubscribers, 3)
        XCTAssertEqual(readout.treatment.resolvedSubscribers, 3)
        let prevented = try XCTUnwrap(readout.preventedCancellations)
        XCTAssertEqual(prevented.estimate, 2.0 / 3.0 - 1.0 / 3.0, accuracy: 1e-9)
    }

    func testEmptyReadoutHasNoRatesAndNoDivisionByZero() {
        let readout = ExperimentReadout.make(from: [])
        XCTAssertNil(readout.treatment.cancellationRate)
        XCTAssertNil(readout.treatment.cancellationInterval)
        XCTAssertNil(readout.preventedCancellations)
    }

    func testPolicyClamps() throws {
        let policy = AttributionPolicy(windowMilliseconds: -1, clockSkewToleranceMilliseconds: 99)
        XCTAssertEqual(policy.windowMilliseconds, 1)
        XCTAssertEqual(policy.clockSkewToleranceMilliseconds, 1)
        let decoded = try JSONDecoder().decode(AttributionPolicy.self, from: Data(#"{"windowMilliseconds":-1,"clockSkewToleranceMilliseconds":99}"#.utf8))
        XCTAssertEqual(decoded, policy, "decoding goes through the same clamps")
        _ = AttributionEngine(policy: AttributionPolicy(windowMilliseconds: .max, clockSkewToleranceMilliseconds: .max))
            .attribute(decisions: [record("d", at: .max)], facts: [], asOf: .max)
    }
}

/// Seeded, platform-independent generator so a failing shuffle is reproducible.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
