import Foundation

/// The real-time decision service behind Apple's Get Retention Message endpoint.
///
/// Guarantees:
/// - **Always answers inside the budget.** Every step that can wait — the remote feature lookup,
///   offer signing — is raced against its slice of ``EngineConfiguration/responseBudget`` with
///   ``raceDeadline(_:on:operation:)``, which never waits for the loser. Everything after the
///   last await is synchronous lookups, so a late dependency costs the personalized answer, never
///   the deadline.
/// - **Fails safe, explicitly.** When the personalized path cannot finish, the engine answers with
///   the product's approved safe-fallback message rather than timing out. A timeout is ambiguous —
///   nobody knows afterwards what the subscriber saw — while an explicit fallback is logged and can
///   be attributed.
/// - **Idempotent per `requestIdentifier`.** Concurrent duplicates share one pipeline run;
///   later duplicates are served from a bounded replay cache, byte for byte.
/// - **No LLM, no network you didn't configure.** The catalog is compiled offline.
public actor DecisionEngine {
    public nonisolated let configuration: EngineConfiguration
    public nonisolated let catalog: CatalogHolder
    public nonisolated let store: FeatureStore
    public nonisolated let breaker: DependencyBreaker

    /// The clock every deadline is measured on. Stamp request arrival with this clock.
    public nonisolated let clock: any DeadlineClock

    private nonisolated let pipeline: DecisionPipeline
    private nonisolated let sink: (any DecisionSink)?

    private var replayCache: BoundedTTLCache<ReplayKey, Decision>
    private var inFlight: [ReplayKey: Task<Decision, Never>] = [:]

    /// How many requests ran the full pipeline (excludes replays).
    public private(set) var pipelineRuns = 0
    /// How many requests were answered as replays.
    public private(set) var replays = 0

    public init(
        configuration: EngineConfiguration,
        catalog: CatalogHolder,
        store: FeatureStore,
        remote: (any FeatureSource)? = nil,
        signer: (any OfferSigner)? = nil,
        sink: (any DecisionSink)? = nil,
        clock: any DeadlineClock = SystemDeadlineClock()
    ) {
        let breaker = DependencyBreaker(
            failureThreshold: configuration.breakerFailureThreshold,
            openDuration: configuration.breakerOpenDuration
        )
        self.configuration = configuration
        self.catalog = catalog
        self.store = store
        self.breaker = breaker
        self.clock = clock
        self.sink = sink
        self.pipeline = DecisionPipeline(
            configuration: configuration,
            catalog: catalog,
            store: store,
            remote: remote,
            signer: signer,
            breaker: breaker,
            clock: clock
        )
        self.replayCache = BoundedTTLCache(capacity: configuration.replayCacheCapacity, ttl: configuration.replayTTL)
    }

    public var inFlightCount: Int { inFlight.count }

    /// Decides for one verified request. Never throws and never waits past the budget.
    ///
    /// - Parameter receivedAt: When the request arrived, on the engine's clock. Defaults to now;
    ///   pass the real arrival time so parsing and verification are charged to the budget.
    public func decide(_ request: DecodedRealtimeRequest, receivedAt: Duration? = nil) async -> Decision {
        let start = Self.clampArrival(receivedAt, now: clock.now())
        // Keyed by Apple's request identifier *and* the request's content (minus `signedDate`), so
        // two different requests that happen to share an identifier can never be confused.
        let key = ReplayKey(requestIdentifier: request.requestIdentifier, identity: request.replayIdentity)

        if let cached = replayCache.value(for: key, now: clock.now()) {
            return recordReplay(of: cached, start: start)
        }
        if let running = inFlight[key] {
            // Suspension point: nothing after it depends on state read before it.
            return recordReplay(of: await running.value, start: start)
        }

        let pipeline = self.pipeline
        let task = Task { await pipeline.run(request, receivedAt: start) }
        // Registered before the first suspension, so a concurrent duplicate finds it.
        inFlight[key] = task
        pipelineRuns += 1
        let decision = await task.value
        if inFlight[key] == task { inFlight[key] = nil }
        replayCache.insert(decision, for: key, now: clock.now())
        sink?.record(decision.record)
        return decision
    }

    /// Arrival can't be in the future, and anything older than the Apple timeout is treated as
    /// exactly that old — the request is already lost either way, and the bound keeps every
    /// `Duration` sum far from overflow whatever a caller passes.
    static func clampArrival(_ receivedAt: Duration?, now: Duration) -> Duration {
        guard let receivedAt else { return now }
        return min(max(receivedAt, now - EngineConfiguration.appleTimeout), now)
    }

    private func recordReplay(of original: Decision, start: Duration) -> Decision {
        replays += 1
        let replay = original.replay(timings: StageTimings(total: clock.now() - start))
        sink?.record(replay.record)
        return replay
    }
}

struct ReplayKey: Hashable, Sendable {
    let requestIdentifier: String
    let identity: DecodedRealtimeRequest.ReplayIdentity
}

extension DecodedRealtimeRequest {
    /// Everything except `signedDate`: a re-signed copy of the same request is still the same request.
    struct ReplayIdentity: Hashable, Sendable {
        let originalTransactionId: String
        let appAppleId: Int64
        let productId: String
        let userLocale: String
        let environment: AppStoreEnvironment
    }

    var replayIdentity: ReplayIdentity {
        ReplayIdentity(
            originalTransactionId: originalTransactionId,
            appAppleId: appAppleId,
            productId: productId,
            userLocale: userLocale,
            environment: environment
        )
    }
}

/// The decision pipeline itself: a value type with no mutable state, so it runs concurrently for
/// many requests without touching the actor.
struct DecisionPipeline: Sendable {
    let configuration: EngineConfiguration
    let catalog: CatalogHolder
    let store: FeatureStore
    let remote: (any FeatureSource)?
    let signer: (any OfferSigner)?
    let breaker: DependencyBreaker
    let clock: any DeadlineClock

    func run(_ request: DecodedRealtimeRequest, receivedAt: Duration) async -> Decision {
        let snapshot = catalog.snapshot()
        let arm = configuration.experiment.arm(for: request.originalTransactionId)
        var draft = Draft(request: request, arm: arm, catalogVersion: snapshot.version, receivedAt: receivedAt)
        let budgetEnd = receivedAt + configuration.responseBudget

        // With nothing approved to say for this product and locale, let Apple's own fallback speak.
        guard let messages = snapshot.productLocaleMessages(productId: request.productId, locale: request.userLocale) else {
            return draft.finish(.deferToApple, response: nil, locale: nil, clock: clock)
        }
        let safeFallback = RealtimeResponse.message(messageIdentifier: messages.safeFallbackMessageId)

        // Holdout is decided before any lookup: intent-to-treat, unaffected by dependency health.
        if arm == .holdout {
            return draft.finish(
                .holdoutControl,
                response: .message(messageIdentifier: messages.controlMessageId),
                locale: messages.locale,
                clock: clock
            )
        }

        let lookupStart = clock.now()
        let (lookup, lookupNotes) = await resolveFeatures(for: request, budgetEnd: budgetEnd)
        draft.notes += lookupNotes
        draft.timings.featureLookup = clock.now() - lookupStart

        let features: SubscriberFeatures
        switch lookup {
        case .found(let found):
            features = found
        case .unavailable(let reason):
            return draft.finish(.fallback(reason), response: safeFallback, locale: messages.locale, clock: clock)
        }

        let segment = features.segment(at: request.signedDate, thresholds: configuration.segmentThresholds)
        draft.segment = segment
        guard let ranked = snapshot.candidates(
            productId: request.productId,
            locale: request.userLocale,
            segment: segment
        ) else {
            return draft.finish(.fallback(.noEligibleCandidate), response: safeFallback, locale: messages.locale, clock: clock)
        }
        let (resolvedLocale, entries) = ranked
        if resolvedLocale != LocaleChain.normalize(request.userLocale) {
            draft.notes.append(.localeFallback)
        }

        let ineligibility = configuration.offerPolicy.ineligibility(of: features, at: request.signedDate)
        for entry in entries {
            switch entry.kind {
            case .text:
                return draft.finish(
                    .personalized,
                    response: .message(messageIdentifier: entry.messageIdentifier),
                    entry: entry,
                    locale: resolvedLocale,
                    clock: clock
                )
            case .switchPlan(let alternateProductId):
                guard alternateProductId != request.productId else {
                    draft.notes.append(.switchPlanSkippedSameProduct)
                    continue
                }
                return draft.finish(
                    .personalized,
                    response: .alternateProduct(messageIdentifier: entry.messageIdentifier, productId: alternateProductId),
                    entry: entry,
                    locale: resolvedLocale,
                    clock: clock
                )
            case .promotionalOffer(let offerId):
                guard ineligibility == nil else {
                    draft.notes.append(.offerIneligible)
                    continue
                }
                guard let signer else {
                    draft.notes.append(.offerSignerUnavailable)
                    continue
                }
                let deadline = budgetEnd - configuration.finalizeReserve
                let signStart = clock.now()
                guard signStart < deadline else {
                    draft.notes.append(.offerSigningSkippedNoBudget)
                    continue
                }
                let productId = request.productId
                let originalTransactionId = request.originalTransactionId
                let outcome = await raceDeadline(deadline, on: clock) {
                    try await signer.signatureV2(
                        productId: productId,
                        offerId: offerId,
                        originalTransactionId: originalTransactionId
                    )
                }
                draft.timings.signing = (draft.timings.signing ?? .zero) + (clock.now() - signStart)
                switch outcome {
                case .value(let signature):
                    return draft.finish(
                        .personalized,
                        response: .promotionalOffer(messageIdentifier: entry.messageIdentifier, signatureV2: signature),
                        entry: entry,
                        locale: resolvedLocale,
                        clock: clock
                    )
                case .timedOut, .cancelled:
                    draft.notes.append(.offerSigningTimedOut)
                case .failed:
                    draft.notes.append(.offerSigningFailed)
                }
            }
        }
        return draft.finish(.fallback(.noEligibleCandidate), response: safeFallback, locale: messages.locale, clock: clock)
    }

    private func resolveFeatures(
        for request: DecodedRealtimeRequest,
        budgetEnd: Duration
    ) async -> (FeatureLookup, [DecisionNote]) {
        let id = request.originalTransactionId
        if let local = store.features(for: id) {
            return (.found(local), [.l1Hit])
        }
        guard let remote else {
            return (.unavailable(.featuresMissing), [.l1Miss, .l2Unavailable])
        }
        // The lookup may use whatever is left after reserving time for signing and finalizing.
        let deadline = budgetEnd - configuration.signingReserve - configuration.finalizeReserve
        let now = clock.now()
        // Budget first: an exhausted request must not consume the breaker's half-open probe.
        guard now < deadline else {
            return (.unavailable(.budgetExhausted), [.l1Miss, .l2SkippedNoBudget])
        }
        guard breaker.shouldAttempt(now: now) else {
            return (.unavailable(.breakerOpen), [.l1Miss, .l2SkippedBreakerOpen])
        }
        let outcome = await raceDeadline(deadline, on: clock) { try await remote.features(for: id) }
        switch outcome {
        case .value(let found?) where found.originalTransactionId == id:
            breaker.recordSuccess()
            store.upsert(found)  // read-through: warm L1 so the next request for this subscriber is a hit
            return (.found(found), [.l1Miss, .l2Hit])
        case .value(.some(_)):
            // The remote returned someone else's record. Never act on it.
            breaker.recordFailure(now: clock.now())
            return (.unavailable(.featuresFailed), [.l1Miss, .l2Failed])
        case .value(.none):
            breaker.recordSuccess()
            return (.unavailable(.featuresMissing), [.l1Miss, .l2Miss])
        case .timedOut:
            breaker.recordFailure(now: clock.now())
            return (.unavailable(.featuresTimedOut), [.l1Miss, .l2TimedOut])
        case .cancelled:
            // Not reachable through `decide` (the pipeline runs in its own task, which nothing
            // cancels), but a cancelled attempt is not a verdict on the remote: give back the probe.
            breaker.abandonProbe()
            return (.unavailable(.featuresTimedOut), [.l1Miss, .l2TimedOut])
        case .failed:
            breaker.recordFailure(now: clock.now())
            return (.unavailable(.featuresFailed), [.l1Miss, .l2Failed])
        }
    }
}

private enum FeatureLookup {
    case found(SubscriberFeatures)
    case unavailable(FallbackReason)
}

private struct Draft {
    let request: DecodedRealtimeRequest
    let arm: Arm
    let catalogVersion: String
    let receivedAt: Duration
    var notes: [DecisionNote] = []
    var timings = StageTimings()
    var segment: Segment?

    init(request: DecodedRealtimeRequest, arm: Arm, catalogVersion: String, receivedAt: Duration) {
        self.request = request
        self.arm = arm
        self.catalogVersion = catalogVersion
        self.receivedAt = receivedAt
    }

    func finish(
        _ path: DecisionPath,
        response: RealtimeResponse?,
        entry: CatalogEntry? = nil,
        locale: String?,
        clock: any DeadlineClock
    ) -> Decision {
        var timings = self.timings
        timings.total = clock.now() - receivedAt
        return Decision(
            decisionId: Decision.identifier(for: request),
            request: request,
            arm: arm,
            path: path,
            response: response,
            entry: entry,
            resolvedLocale: locale,
            segment: segment,
            notes: notes,
            timings: timings,
            catalogVersion: catalogVersion
        )
    }
}
