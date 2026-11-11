import XCTest
@testable import RetentionEngine

final class PolicyAndCatalogTests: XCTestCase {
    let policy = OfferPolicy(coolDownMilliseconds: 30 * Fixture.day, maxRedemptionsInWindow: 2, windowMilliseconds: 365 * Fixture.day)

    func features(redeemedDaysAgo: [Int64], intro: Bool = false, retry: Bool = false) -> SubscriberFeatures {
        var features = SubscriberFeatures(originalTransactionId: "p")
        features.merge(Fixture.subscribed("p", daysAgo: 700, intro: intro))
        for (index, days) in redeemedDaysAgo.enumerated() {
            features.merge(SubscriptionFact(notificationUUID: "r\(index)", signedDate: Fixture.now - days * Fixture.day, originalTransactionId: "p", productId: nil, kind: .offerRedeemed(offerId: "o")))
        }
        if retry {
            features.merge(SubscriptionFact(notificationUUID: "retry", signedDate: Fixture.now, originalTransactionId: "p", productId: nil, kind: .billingRetryStarted))
        }
        return features
    }

    func testCoolDownBoundaryIsExclusive() {
        XCTAssertNil(policy.ineligibility(of: features(redeemedDaysAgo: [30]), at: Fixture.now), "exactly at the cool-down is eligible")
        XCTAssertEqual(
            policy.ineligibility(of: features(redeemedDaysAgo: [29]), at: Fixture.now),
            .coolDown(remainingMilliseconds: Fixture.day)
        )
    }

    func testFrequencyCapInWindow() {
        XCTAssertEqual(policy.ineligibility(of: features(redeemedDaysAgo: [40, 200]), at: Fixture.now), .frequencyCap(redemptionsInWindow: 2))
        XCTAssertNil(policy.ineligibility(of: features(redeemedDaysAgo: [40, 400]), at: Fixture.now), "older than the window does not count")
    }

    func testSegmentsExcludedByDefault() {
        XCTAssertEqual(policy.ineligibility(of: features(redeemedDaysAgo: [], intro: true), at: Fixture.now), .introOffer)
        XCTAssertEqual(policy.ineligibility(of: features(redeemedDaysAgo: [], retry: true), at: Fixture.now), .billingRetry)
        let permissive = OfferPolicy(coolDownMilliseconds: 0, maxRedemptionsInWindow: 8, windowMilliseconds: 1, allowDuringIntroOffer: true, allowDuringBillingRetry: true)
        XCTAssertNil(permissive.ineligibility(of: features(redeemedDaysAgo: [], intro: true, retry: true), at: Fixture.now))
    }

    func testExtremeInputsDoNotTrap() {
        let extreme = OfferPolicy(coolDownMilliseconds: .max, maxRedemptionsInWindow: 99, windowMilliseconds: .max)
        XCTAssertEqual(extreme.maxRedemptionsInWindow, SubscriberFeatures.redemptionHistoryLimit, "cap clamps to stored history")
        _ = extreme.ineligibility(of: features(redeemedDaysAgo: [1]), at: .min)
        _ = extreme.ineligibility(of: features(redeemedDaysAgo: [1]), at: .max)
        let negative = OfferPolicy(coolDownMilliseconds: -5, maxRedemptionsInWindow: -1, windowMilliseconds: -9)
        XCTAssertEqual(negative.coolDownMilliseconds, 0)
        XCTAssertEqual(negative.maxRedemptionsInWindow, 0)
        XCTAssertEqual(negative.ineligibility(of: features(redeemedDaysAgo: []), at: Fixture.now), .frequencyCap(redemptionsInWindow: 0), "a cap of zero means no offers")
    }

    func testFutureDatedRedemptionCountsAsJustNow() {
        XCTAssertEqual(
            policy.ineligibility(of: features(redeemedDaysAgo: [-1]), at: Fixture.now),
            .coolDown(remainingMilliseconds: 30 * Fixture.day)
        )
    }

    func testLocaleNormalizationAndChain() {
        XCTAssertEqual(LocaleChain.normalize("en_us"), "en-US")
        XCTAssertEqual(LocaleChain.normalize("ZH-hans-cn"), "zh-Hans-CN")
        XCTAssertEqual(LocaleChain.normalize(""), "")
        XCTAssertEqual(LocaleChain.chain(for: "fr_CA", primary: "en-US"), ["fr-CA", "fr", "en-US"])
        XCTAssertEqual(LocaleChain.chain(for: "en-US", primary: "en-US"), ["en-US", "en"])
        XCTAssertEqual(LocaleChain.chain(for: "zh-Hant-TW", primary: "en-US"), ["zh-Hant-TW", "zh-Hant", "zh", "en-US"])
    }

    func testCatalogResolvesThroughTheLocaleChain() throws {
        let catalog = try Fixture.catalog()
        let resolved = try XCTUnwrap(catalog.candidates(productId: Fixture.product, locale: "en-GB", segment: .loyal))
        XCTAssertEqual(resolved.locale, "en-US")
        XCTAssertEqual(resolved.entries.first?.kind, .promotionalOffer(offerId: Fixture.offerId))
        XCTAssertNil(catalog.candidates(productId: "unknown", locale: "en-US", segment: .loyal))
        XCTAssertEqual(catalog.productLocaleMessages(productId: Fixture.product, locale: "ja-JP")?.safeFallbackMessageId, Fixture.safeMessage)
        XCTAssertNil(catalog.productLocaleMessages(productId: "unknown", locale: "en-US"))
    }

    func testCatalogRefusesEntriesItCannotFailSafeFor() {
        let key = CatalogKey(productId: "orphan", locale: "de-DE", segment: .loyal)
        XCTAssertThrowsError(try MessageCatalog(primaryLocale: "en-US", entries: [key: [CatalogEntry(messageIdentifier: "m", variantId: "v", kind: .text)]], productLocales: [])) {
            XCTAssertEqual($0 as? CatalogError, .missingFallback(productId: "orphan", locale: "de-DE"))
        }
        let same = CatalogKey(productId: Fixture.product, locale: "en-US", segment: .loyal)
        XCTAssertThrowsError(try MessageCatalog(
            primaryLocale: "en-US",
            entries: [same: [CatalogEntry(messageIdentifier: "m", variantId: "v", kind: .switchPlan(alternateProductId: Fixture.product))]],
            productLocales: [ProductLocaleMessages(productId: Fixture.product, locale: "en-US", safeFallbackMessageId: "s", controlMessageId: "c")]
        )) { XCTAssertEqual($0 as? CatalogError, .switchPlanToSameProduct(productId: Fixture.product)) }
    }

    func testCatalogCodableRoundTripRevalidates() throws {
        let catalog = try Fixture.catalog()
        let data = try JSONEncoder().encode(catalog)
        let decoded = try JSONDecoder().decode(MessageCatalog.self, from: data)
        XCTAssertEqual(decoded, catalog)
        XCTAssertEqual(decoded.version, catalog.version)
        // Remove the fallbacks from the JSON: decoding must fail rather than produce an unsafe catalog.
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["productLocales"] = [Any]()
        let tampered = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(MessageCatalog.self, from: tampered))
    }

    func testCatalogVersionTracksContent() throws {
        let a = try Fixture.catalog()
        // Regression pin: the fingerprint is FNV-1a over a canonical string, so it is the same in
        // every process. (A `Hasher`-based fingerprint would fail this in the next test run.)
        XCTAssertEqual(a.version, "21b8b130b0f9a7f4")
        let changed = try MessageCatalog(
            primaryLocale: "en-US",
            entries: [CatalogKey(productId: Fixture.product, locale: "en-US", segment: .new): [CatalogEntry(messageIdentifier: "other", variantId: "v", kind: .text)]],
            productLocales: [ProductLocaleMessages(productId: Fixture.product, locale: "en-US", safeFallbackMessageId: Fixture.safeMessage, controlMessageId: Fixture.controlMessage)]
        )
        XCTAssertNotEqual(changed.version, a.version)
        XCTAssertEqual(a.version.count, 16)
    }

    /// Smoke test (not a proof — run under TSan for that): concurrent publishes and snapshots,
    /// every snapshot internally coherent with its own version.
    func testSnapshotsStayCoherentUnderConcurrentPublishes() async throws {
        let full = try Fixture.catalog()
        let holder = CatalogHolder(.empty)
        let key = CatalogKey(productId: Fixture.product, locale: "en-US", segment: .loyal)
        let incoherent = Locked(0)
        await withTaskGroup(of: Void.self) { group in
            // Ends on `full`, so a holder whose publish did nothing fails the check below.
            group.addTask { for index in 0..<2_000 { holder.publish(index.isMultiple(of: 2) ? .empty : full) } }
            for _ in 0..<4 {
                group.addTask {
                    for _ in 0..<2_000 {
                        let snapshot = holder.snapshot()
                        let coherent = snapshot.version == full.version ? snapshot.entries(for: key).count == 3 : snapshot.entryCount == 0
                        if !coherent { incoherent.withLock { $0 += 1 } }
                    }
                }
            }
        }
        XCTAssertEqual(incoherent.withLock { $0 }, 0)
        XCTAssertEqual(holder.snapshot().version, full.version, "the last publish is what the next snapshot sees")
    }

    func testPublishIsVisibleToTheNextSnapshot() throws {
        let full = try Fixture.catalog()
        let holder = CatalogHolder(.empty)
        XCTAssertEqual(holder.snapshot().entryCount, 0)
        holder.publish(full)
        XCTAssertEqual(holder.snapshot().version, full.version)
        XCTAssertGreaterThan(holder.snapshot().entryCount, 0)
        holder.publish(.empty)
        XCTAssertEqual(holder.snapshot().version, MessageCatalog.empty.version)
    }

    /// Decoding goes through the same clamps as the initializers: a configuration file can't make
    /// the frequency cap unlimited or the holdout larger than everyone.
    func testDecodingGoesThroughTheClamps() throws {
        let decoder = JSONDecoder()
        let policy = try decoder.decode(OfferPolicy.self, from: Data(#"{"coolDownMilliseconds":-5,"maxRedemptionsInWindow":99,"windowMilliseconds":-1,"allowDuringIntroOffer":false,"allowDuringBillingRetry":true}"#.utf8))
        XCTAssertEqual(policy.coolDownMilliseconds, 0)
        XCTAssertEqual(policy.maxRedemptionsInWindow, SubscriberFeatures.redemptionHistoryLimit)
        XCTAssertEqual(policy.windowMilliseconds, 0)
        XCTAssertTrue(policy.allowDuringBillingRetry)
        let assigner = try decoder.decode(ExperimentAssigner.self, from: Data(#"{"salt":"s","holdoutBasisPoints":25000}"#.utf8))
        XCTAssertEqual(assigner.holdoutBasisPoints, 10_000)
        let thresholds = try decoder.decode(SegmentThresholds.self, from: Data(#"{"establishedAfterMilliseconds":100,"loyalAfterMilliseconds":5}"#.utf8))
        XCTAssertEqual(thresholds.loyalAfterMilliseconds, 100)
        XCTAssertEqual(try decoder.decode(OfferPolicy.self, from: try JSONEncoder().encode(OfferPolicy.default)), .default, "round trip")
        XCTAssertEqual(try decoder.decode(SegmentThresholds.self, from: try JSONEncoder().encode(SegmentThresholds.default)), .default)
    }

    func testDecodedKeysAreNormalizedAndReachable() throws {
        let json = #"{"primaryLocale":"en_us","entries":[{"key":{"productId":"p","locale":"en_us","segment":"loyal"},"entries":[{"messageIdentifier":"m","variantId":"v","kind":{"text":{}}}]}],"productLocales":[{"productId":"p","locale":"EN_us","safeFallbackMessageId":"s","controlMessageId":"c"}]}"#
        let catalog = try JSONDecoder().decode(MessageCatalog.self, from: Data(json.utf8))
        XCTAssertEqual(catalog.candidates(productId: "p", locale: "en-US", segment: .loyal)?.entries.first?.messageIdentifier, "m")
        XCTAssertEqual(catalog.productLocaleMessages(productId: "p", locale: "en-US")?.safeFallbackMessageId, "s")
    }

    func testCompactionDropsOnlyLongEndedSubscriptions() {
        let store = FeatureStore()
        store.ingest(Fixture.subscribed("active", daysAgo: 400))
        store.ingest(Fixture.subscribed("ended-long-ago", daysAgo: 400))
        store.ingest(SubscriptionFact(notificationUUID: "e1", signedDate: Fixture.now - 100 * Fixture.day, originalTransactionId: "ended-long-ago", productId: nil, kind: .expired))
        store.ingest(Fixture.subscribed("ended-recently", daysAgo: 400))
        store.ingest(SubscriptionFact(notificationUUID: "e2", signedDate: Fixture.now - 5 * Fixture.day, originalTransactionId: "ended-recently", productId: nil, kind: .expired))
        XCTAssertEqual(store.compact(inactiveBefore: Fixture.now - 30 * Fixture.day), 1)
        XCTAssertNil(store.features(for: "ended-long-ago"))
        XCTAssertNotNil(store.features(for: "ended-recently"))
        XCTAssertNotNil(store.features(for: "active"))
    }

    func testBreakerTransitions() {
        let breaker = DependencyBreaker(failureThreshold: 2, openDuration: .seconds(5))
        XCTAssertTrue(breaker.shouldAttempt(now: .zero))
        breaker.recordFailure(now: .zero)
        XCTAssertEqual(breaker.currentState, .closed(consecutiveFailures: 1))
        breaker.recordSuccess()
        breaker.recordFailure(now: .zero)
        breaker.recordFailure(now: .seconds(1))
        XCTAssertEqual(breaker.currentState, .open(until: .seconds(6)))
        XCTAssertFalse(breaker.shouldAttempt(now: .seconds(5)))
        XCTAssertTrue(breaker.shouldAttempt(now: .seconds(6)), "half-open lets one probe through")
        XCTAssertFalse(breaker.shouldAttempt(now: .seconds(6)), "…and only one")
        breaker.abandonProbe()
        XCTAssertEqual(breaker.currentState, .halfOpen(probeInFlight: false), "an abandoned probe is given back")
        XCTAssertTrue(breaker.shouldAttempt(now: .seconds(6)))
        breaker.recordFailure(now: .seconds(7))
        XCTAssertEqual(breaker.currentState, .open(until: .seconds(12)))
        XCTAssertTrue(breaker.shouldAttempt(now: .seconds(12)))
        breaker.recordSuccess()
        XCTAssertEqual(breaker.currentState, .closed(consecutiveFailures: 0))
        XCTAssertEqual(DependencyBreaker(failureThreshold: 0, openDuration: .zero).failureThreshold, 1)
    }

    func testBoundedCacheNeverExceedsCapacityAndExpires() {
        var cache = BoundedTTLCache<String, Int>(capacity: 3, ttl: .seconds(10))
        for index in 0..<100 { cache.insert(index, for: "k\(index)", now: .zero) }
        XCTAssertEqual(cache.count, 3)
        XCTAssertEqual(cache.value(for: "k99", now: .zero), 99)
        XCTAssertNil(cache.value(for: "k0", now: .zero), "evicted in insertion order")
        XCTAssertNil(cache.value(for: "k99", now: .seconds(11)), "expired")
        XCTAssertEqual(cache.count, 2)
    }

    /// An expired key re-inserted must not be evicted by its *old* ring slot.
    func testReinsertedKeySurvivesItsOldSlot() {
        var cache = BoundedTTLCache<String, Int>(capacity: 2, ttl: .seconds(1))
        cache.insert(1, for: "a", now: .zero)                 // slot 0
        XCTAssertNil(cache.value(for: "a", now: .seconds(2)))  // expired, removed
        cache.insert(2, for: "a", now: .seconds(2))            // slot 1
        cache.insert(3, for: "b", now: .seconds(2))            // slot 0: the stale "a" entry must not take the new "a" with it
        XCTAssertEqual(cache.value(for: "a", now: .seconds(2)), 2)
        XCTAssertEqual(cache.value(for: "b", now: .seconds(2)), 3)
        XCTAssertEqual(BoundedTTLCache<String, Int>(capacity: 0, ttl: .zero).capacity, 1)
    }

    func testConfigurationClampsEverything() {
        let wild = EngineConfiguration(
            appAppleId: 1,
            environment: .sandbox,
            responseBudget: .seconds(30),
            signingReserve: .seconds(30),
            finalizeReserve: .seconds(-1),
            verificationBudget: .zero,
            maxRequestBytes: -1,
            replayCacheCapacity: 0,
            replayTTL: .seconds(-5),
            experiment: ExperimentAssigner(salt: "s", holdoutBasisPoints: 0),
            breakerFailureThreshold: -3,
            breakerOpenDuration: .seconds(999_999)
        )
        XCTAssertEqual(wild.responseBudget, .milliseconds(700))
        XCTAssertEqual(wild.signingReserve, .milliseconds(350))
        XCTAssertEqual(wild.finalizeReserve, .zero)
        XCTAssertEqual(wild.verificationBudget, .milliseconds(1))
        XCTAssertEqual(wild.maxRequestBytes, 1_024)
        XCTAssertEqual(wild.replayCacheCapacity, 1)
        XCTAssertEqual(wild.replayTTL, .zero)
        XCTAssertEqual(wild.breakerFailureThreshold, 1)
        XCTAssertEqual(wild.breakerOpenDuration, .seconds(3_600))
        XCTAssertEqual(EngineConfiguration(appAppleId: 1, environment: .sandbox, responseBudget: .zero, experiment: .init(salt: "s", holdoutBasisPoints: 0)).responseBudget, .milliseconds(1))
    }
}
