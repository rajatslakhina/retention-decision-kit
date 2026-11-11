import Foundation

/// Immutable engine configuration. Every value is validated once, here; nothing downstream
/// re-checks it, and nothing can mutate it after the engine starts.
public struct EngineConfiguration: Sendable {
    /// Apple's production timeout for the Get Retention Message endpoint.
    public static let appleTimeout: Duration = .milliseconds(700)

    public let appAppleId: Int64
    public let environment: AppStoreEnvironment

    /// Time from receiving the request to having the response ready, clamped to `1 ms...700 ms`.
    /// Apple's 700 ms includes the network and TLS on both legs, so the default leaves 250 ms of it.
    public let responseBudget: Duration
    /// Part of the budget kept back for signing a promotional offer after the feature lookup.
    public let signingReserve: Duration
    /// Part of the budget kept back for encoding and writing the response.
    public let finalizeReserve: Duration
    /// The slice of the budget signature verification may use.
    public let verificationBudget: Duration
    /// Request bodies larger than this are rejected before parsing.
    public let maxRequestBytes: Int

    public let replayCacheCapacity: Int
    public let replayTTL: Duration

    public let experiment: ExperimentAssigner
    public let offerPolicy: OfferPolicy
    public let segmentThresholds: SegmentThresholds

    public let breakerFailureThreshold: Int
    public let breakerOpenDuration: Duration

    public init(
        appAppleId: Int64,
        environment: AppStoreEnvironment,
        responseBudget: Duration = .milliseconds(450),
        signingReserve: Duration = .milliseconds(80),
        finalizeReserve: Duration = .milliseconds(10),
        verificationBudget: Duration = .milliseconds(60),
        maxRequestBytes: Int = 64 * 1024,
        replayCacheCapacity: Int = 50_000,
        replayTTL: Duration = .seconds(600),
        experiment: ExperimentAssigner,
        offerPolicy: OfferPolicy = .default,
        segmentThresholds: SegmentThresholds = .default,
        breakerFailureThreshold: Int = 20,
        breakerOpenDuration: Duration = .seconds(5)
    ) {
        let budget = min(max(responseBudget, .milliseconds(1)), Self.appleTimeout)
        self.appAppleId = appAppleId
        self.environment = environment
        self.responseBudget = budget
        self.signingReserve = min(max(signingReserve, .zero), budget / 2)
        self.finalizeReserve = min(max(finalizeReserve, .zero), budget / 4)
        self.verificationBudget = min(max(verificationBudget, .milliseconds(1)), budget / 2)
        self.maxRequestBytes = min(max(maxRequestBytes, 1_024), 1_048_576)
        self.replayCacheCapacity = min(max(replayCacheCapacity, 1), 5_000_000)
        self.replayTTL = min(max(replayTTL, .zero), .seconds(86_400))
        self.experiment = experiment
        self.offerPolicy = offerPolicy
        self.segmentThresholds = segmentThresholds
        self.breakerFailureThreshold = max(1, breakerFailureThreshold)
        self.breakerOpenDuration = min(max(breakerOpenDuration, .zero), .seconds(3_600))
    }
}
