import Foundation
@testable import RetentionEngine

enum Fixture {
    static let appAppleId: Int64 = 1_234_567_890
    static let product = "pro.monthly"
    static let yearly = "pro.yearly"
    static let lite = "lite.monthly"
    static let offerId = "retention_50"
    static let now: Int64 = 1_794_268_800_000
    static let day: Int64 = 86_400_000

    static let safeMessage = "safe-en"
    static let controlMessage = "control-en"
    static let offerMessage = "offer-en"
    static let textMessage = "text-en"
    static let switchMessage = "switch-en"

    /// An assigner with no holdout, so every subscriber is in treatment unless a test says otherwise.
    static func configuration(
        holdoutBasisPoints: Int = 0,
        budget: Duration = .milliseconds(450),
        breakerFailureThreshold: Int = 20,
        replayCapacity: Int = 1_000,
        replayTTL: Duration = .seconds(600)
    ) -> EngineConfiguration {
        EngineConfiguration(
            appAppleId: appAppleId,
            environment: .production,
            responseBudget: budget,
            replayCacheCapacity: replayCapacity,
            replayTTL: replayTTL,
            experiment: ExperimentAssigner(salt: "test", holdoutBasisPoints: holdoutBasisPoints),
            breakerFailureThreshold: breakerFailureThreshold,
            breakerOpenDuration: .seconds(5)
        )
    }

    /// loyal/established: offer, then switch, then text. Everything else: text.
    static func catalog() throws -> MessageCatalog {
        var entries: [CatalogKey: [CatalogEntry]] = [:]
        for product in [product, yearly] {
            for segment in Segment.allCases {
                let key = CatalogKey(productId: product, locale: "en-US", segment: segment)
                switch segment {
                case .loyal, .established:
                    entries[key] = [
                        CatalogEntry(messageIdentifier: offerMessage, variantId: "v-offer", kind: .promotionalOffer(offerId: offerId)),
                        CatalogEntry(messageIdentifier: switchMessage, variantId: "v-switch", kind: .switchPlan(alternateProductId: lite)),
                        CatalogEntry(messageIdentifier: textMessage, variantId: "v-text", kind: .text),
                    ]
                default:
                    entries[key] = [CatalogEntry(messageIdentifier: textMessage, variantId: "v-text", kind: .text)]
                }
            }
        }
        return try MessageCatalog(
            primaryLocale: "en-US",
            entries: entries,
            productLocales: [
                ProductLocaleMessages(productId: product, locale: "en-US", safeFallbackMessageId: safeMessage, controlMessageId: controlMessage),
                ProductLocaleMessages(productId: yearly, locale: "en-US", safeFallbackMessageId: safeMessage, controlMessageId: controlMessage),
            ]
        )
    }

    static func request(
        _ originalTransactionId: String = "loyal-1",
        product: String = product,
        locale: String = "en-US",
        requestIdentifier: String = UUID().uuidString,
        appAppleId: Int64 = appAppleId,
        environment: AppStoreEnvironment = .production,
        signedDate: Int64 = now
    ) -> DecodedRealtimeRequest {
        DecodedRealtimeRequest(
            originalTransactionId: originalTransactionId,
            appAppleId: appAppleId,
            productId: product,
            userLocale: locale,
            requestIdentifier: requestIdentifier,
            environment: environment,
            signedDate: signedDate
        )
    }

    static func subscribed(_ id: String, daysAgo: Int64, intro: Bool = false, product: String = product) -> SubscriptionFact {
        SubscriptionFact(
            notificationUUID: "sub-\(id)-\(daysAgo)",
            signedDate: now - daysAgo * day,
            originalTransactionId: id,
            productId: product,
            kind: .subscribed(purchaseDate: now - daysAgo * day, inIntroOffer: intro)
        )
    }

    static func loyalFeatures(_ id: String) -> SubscriberFeatures {
        var features = SubscriberFeatures(originalTransactionId: id)
        features.merge(subscribed(id, daysAgo: 500))
        return features
    }

    static func store(with ids: [String]) -> FeatureStore {
        let store = FeatureStore(shardCount: 4)
        for id in ids { store.ingest(subscribed(id, daysAgo: 500)) }
        return store
    }
}

/// A source whose calls park until released; optionally ignores cancellation entirely.
final class GatedSource: FeatureSource, @unchecked Sendable {
    // @unchecked: all state behind `state`'s lock.
    private struct State {
        var calls = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
        var released = false
    }

    private let state = Locked(State())
    let result: SubscriberFeatures?
    let failure: (any Error)?

    init(result: SubscriberFeatures?, failure: (any Error)? = nil) {
        self.result = result
        self.failure = failure
    }

    var calls: Int { state.withLock { $0.calls } }

    func features(for originalTransactionId: String) async throws -> SubscriberFeatures? {
        let mustWait = state.withLock { state -> Bool in
            state.calls += 1
            return !state.released
        }
        if mustWait {
            // Deliberately not cancellation-aware: models a client that never notices cancellation.
            await withCheckedContinuation { continuation in
                let resumeNow = state.withLock { state -> Bool in
                    if state.released { return true }
                    state.waiters.append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        if let failure { throw failure }
        return result
    }

    func release() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.released = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

struct ImmediateSource: FeatureSource {
    let result: SubscriberFeatures?
    func features(for originalTransactionId: String) async throws -> SubscriberFeatures? { result }
}

struct FailingSource: FeatureSource {
    struct Boom: Error {}
    let calls: Locked<Int>
    func features(for originalTransactionId: String) async throws -> SubscriberFeatures? {
        calls.withLock { $0 += 1 }
        throw Boom()
    }
}

final class GatedSigner: OfferSigner, @unchecked Sendable {
    // @unchecked: wraps a GatedSource-style gate behind a lock.
    private let gate = GatedSource(result: nil)
    func signatureV2(productId: String, offerId: String, originalTransactionId: String) async throws -> String {
        _ = try await gate.features(for: originalTransactionId)
        return "sig"
    }
    func release() { gate.release() }
}

struct InstantSigner: OfferSigner {
    func signatureV2(productId: String, offerId: String, originalTransactionId: String) async throws -> String {
        "sig-\(offerId)-\(originalTransactionId)"
    }
}

/// SplitMix64: a tiny, seedable, platform-independent generator for reproducible test data.
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

/// Awaits `task` for at most `seconds` of real time. A deadline bug on a manual clock would
/// otherwise hang the suite instead of failing it.
func completes<T: Sendable>(_ task: Task<T, Never>, within seconds: Int = 20) async -> T? {
    let outcome = await raceDeadline(SystemDeadlineClock().now() + .seconds(seconds), on: SystemDeadlineClock()) {
        await task.value
    }
    if case .value(let value) = outcome { return value }
    return nil
}

/// A cooperative dependency whose latency is measured on the engine's clock.
struct ClockedSource: FeatureSource {
    let clock: ManualClock
    let latency: Duration
    let result: SubscriberFeatures?
    func features(for originalTransactionId: String) async throws -> SubscriberFeatures? {
        try await clock.sleep(until: clock.now() + latency)
        return result
    }
}

struct ClockedSigner: OfferSigner {
    let clock: ManualClock
    let latency: Duration
    func signatureV2(productId: String, offerId: String, originalTransactionId: String) async throws -> String {
        try await clock.sleep(until: clock.now() + latency)
        return "sig"
    }
}

/// Fails the first `failures` calls, then returns `result`.
final class FlakySource: FeatureSource, Sendable {
    private let state: Locked<Int>
    let failures: Int
    let result: SubscriberFeatures?
    init(failures: Int, result: SubscriberFeatures?) {
        self.failures = failures
        self.result = result
        state = Locked(0)
    }
    var calls: Int { state.withLock { $0 } }
    func features(for originalTransactionId: String) async throws -> SubscriberFeatures? {
        let call = state.withLock { calls -> Int in
            calls += 1
            return calls
        }
        if call <= failures { throw FailingSource.Boom() }
        return result
    }
}
