import XCTest
@testable import RetentionEngine

final class DecisionEngineTests: XCTestCase {
    func makeEngine(
        clock: ManualClock,
        store: FeatureStore = Fixture.store(with: ["loyal-1"]),
        remote: (any FeatureSource)? = nil,
        signer: (any OfferSigner)? = InstantSigner(),
        configuration: EngineConfiguration = Fixture.configuration(),
        sink: (any DecisionSink)? = nil
    ) throws -> DecisionEngine {
        DecisionEngine(
            configuration: configuration,
            catalog: CatalogHolder(try Fixture.catalog()),
            store: store,
            remote: remote,
            signer: signer,
            sink: sink,
            clock: clock
        )
    }

    func testLoyalSubscriberGetsASignedOffer() async throws {
        let clock = ManualClock()
        let engine = try makeEngine(clock: clock)
        let decision = await engine.decide(Fixture.request("loyal-1"))
        XCTAssertEqual(decision.path, .personalized)
        XCTAssertEqual(decision.response, .promotionalOffer(messageIdentifier: Fixture.offerMessage, signatureV2: "sig-retention_50-loyal-1"))
        XCTAssertEqual(decision.segment, .loyal)
        XCTAssertEqual(decision.notes, [.l1Hit])
        XCTAssertEqual(decision.record.offerId, Fixture.offerId)
        XCTAssertEqual(decision.record.variantId, "v-offer")
        XCTAssertEqual(decision.arm, .treatment)
    }

    func testHoldoutGetsControlWithoutAnyLookup() async throws {
        let clock = ManualClock()
        let remote = GatedSource(result: nil)
        let engine = try makeEngine(clock: clock, store: FeatureStore(), remote: remote, configuration: Fixture.configuration(holdoutBasisPoints: 10_000))
        let decisionResult = await completes(Task { await engine.decide(Fixture.request("anyone")) })
        let decision = try XCTUnwrap(decisionResult, "a holdout decision must not wait on the remote")
        XCTAssertEqual(decision.path, .holdoutControl)
        XCTAssertEqual(decision.response, .message(messageIdentifier: Fixture.controlMessage))
        XCTAssertEqual(remote.calls, 0, "holdout is decided before features, so dependency health cannot bias it")
        remote.release()
    }

    func testIneligibleOfferFallsThroughToSwitchPlan() async throws {
        let store = Fixture.store(with: ["loyal-1"])
        store.ingest(SubscriptionFact(notificationUUID: "redeem", signedDate: Fixture.now - 10 * Fixture.day, originalTransactionId: "loyal-1", productId: nil, kind: .offerRedeemed(offerId: "older")))
        let engine = try makeEngine(clock: ManualClock(), store: store)
        let decision = await engine.decide(Fixture.request("loyal-1"))
        XCTAssertEqual(decision.response, .alternateProduct(messageIdentifier: Fixture.switchMessage, productId: Fixture.lite))
        XCTAssertTrue(decision.notes.contains(.offerIneligible))
        XCTAssertEqual(decision.record.alternateProductId, Fixture.lite)
        XCTAssertNil(decision.record.offerId)
    }

    func testMissingSignerFallsThrough() async throws {
        let engine = try makeEngine(clock: ManualClock(), signer: nil)
        let decision = await engine.decide(Fixture.request("loyal-1"))
        XCTAssertEqual(decision.response, .alternateProduct(messageIdentifier: Fixture.switchMessage, productId: Fixture.lite))
        XCTAssertTrue(decision.notes.contains(.offerSignerUnavailable))
    }

    func testSlowSignerDegradesAtTheSigningDeadline() async throws {
        let clock = ManualClock()
        let signer = GatedSigner()
        let configuration = Fixture.configuration()
        let engine = try makeEngine(clock: clock, signer: signer, configuration: configuration)
        let task = Task { await engine.decide(Fixture.request("loyal-1"), receivedAt: clock.now()) }
        await clock.waitForSleepers(atLeast: 1)
        clock.advance(by: configuration.responseBudget - configuration.finalizeReserve)
        let decisionResult = await completes(task)
        let decision = try XCTUnwrap(decisionResult, "missed the signing deadline")
        XCTAssertEqual(decision.path, .personalized)
        XCTAssertEqual(decision.response, .alternateProduct(messageIdentifier: Fixture.switchMessage, productId: Fixture.lite))
        XCTAssertTrue(decision.notes.contains(.offerSigningTimedOut))
        XCTAssertEqual(decision.timings.total, .milliseconds(440))
        XCTAssertLessThanOrEqual(decision.timings.total, configuration.responseBudget)
        XCTAssertNil(decision.record.offerId, "an offer that was never signed was never shown")
        signer.release()
    }

    func testColdSubscriberUsesTheRemoteAndWarmsTheLocalStore() async throws {
        let store = FeatureStore()
        let engine = try makeEngine(clock: ManualClock(), store: store, remote: ImmediateSource(result: Fixture.loyalFeatures("cold-1")))
        let decision = await engine.decide(Fixture.request("cold-1"))
        XCTAssertEqual(decision.path, .personalized)
        XCTAssertEqual(decision.notes.prefix(2), [.l1Miss, .l2Hit])
        XCTAssertNotNil(store.features(for: "cold-1"), "read-through: the next request is a local hit")
        let second = await engine.decide(Fixture.request("cold-1"))
        XCTAssertEqual(second.notes.first, .l1Hit)
    }

    /// A remote that never answers — and never notices cancellation — costs exactly the lookup's
    /// slice of the budget, and the subscriber still gets an approved message.
    func testHungRemoteFallsBackExactlyAtTheLookupDeadline() async throws {
        let clock = ManualClock()
        let remote = GatedSource(result: Fixture.loyalFeatures("cold-1"))
        let configuration = Fixture.configuration()
        let engine = try makeEngine(clock: clock, store: FeatureStore(), remote: remote, configuration: configuration)
        let task = Task { await engine.decide(Fixture.request("cold-1"), receivedAt: clock.now()) }
        await clock.waitForSleepers(atLeast: 1)
        clock.advance(by: configuration.responseBudget - configuration.signingReserve - configuration.finalizeReserve)
        let decisionResult = await completes(task)
        let decision = try XCTUnwrap(decisionResult, "missed the lookup deadline")
        XCTAssertEqual(decision.path, .fallback(.featuresTimedOut))
        XCTAssertEqual(decision.response, .message(messageIdentifier: Fixture.safeMessage))
        XCTAssertEqual(decision.timings.total, .milliseconds(360))
        XCTAssertEqual(decision.notes, [.l1Miss, .l2TimedOut])
        remote.release()
    }

    func testRemoteMissAndAbsentRemoteBothFallBack() async throws {
        let miss = try makeEngine(clock: ManualClock(), store: FeatureStore(), remote: ImmediateSource(result: nil))
        let missed = await miss.decide(Fixture.request("cold-1"))
        XCTAssertEqual(missed.path, .fallback(.featuresMissing))
        XCTAssertEqual(missed.notes, [.l1Miss, .l2Miss])
        XCTAssertEqual(miss.breaker.currentState, .closed(consecutiveFailures: 0), "a miss is an answer, not a failure")
        let none = try makeEngine(clock: ManualClock(), store: FeatureStore(), remote: nil)
        let absent = await none.decide(Fixture.request("cold-1"))
        XCTAssertEqual(absent.path, .fallback(.featuresMissing))
        XCTAssertEqual(absent.notes, [.l1Miss, .l2Unavailable])
    }

    func testRemoteRecordForAnotherSubscriberIsNeverUsed() async throws {
        let store = FeatureStore()
        let engine = try makeEngine(clock: ManualClock(), store: store, remote: ImmediateSource(result: Fixture.loyalFeatures("someone-else")))
        let decision = await engine.decide(Fixture.request("cold-1"))
        XCTAssertEqual(decision.path, .fallback(.featuresFailed))
        XCTAssertEqual(store.count, 0)
    }

    func testBreakerOpensAndStopsCallingTheRemote() async throws {
        let calls = Locked(0)
        let engine = try makeEngine(
            clock: ManualClock(),
            store: FeatureStore(),
            remote: FailingSource(calls: calls),
            configuration: Fixture.configuration(breakerFailureThreshold: 2)
        )
        var paths: [DecisionPath] = []
        for index in 0..<4 { paths.append(await engine.decide(Fixture.request("cold-\(index)")).path) }
        XCTAssertEqual(paths, [.fallback(.featuresFailed), .fallback(.featuresFailed), .fallback(.breakerOpen), .fallback(.breakerOpen)])
        XCTAssertEqual(calls.withLock { $0 }, 2)
    }

    /// README decision 9: a remote that times out opens the breaker like one that fails, so a hung
    /// cache stops costing every L1 miss the full lookup slice.
    func testTimeoutsOpenTheBreaker() async throws {
        let clock = ManualClock()
        let remote = GatedSource(result: nil)
        let engine = try makeEngine(clock: clock, store: FeatureStore(), remote: remote, configuration: Fixture.configuration(breakerFailureThreshold: 2))
        var paths: [DecisionPath] = []
        for index in 0..<2 {
            let task = Task { await engine.decide(Fixture.request("cold-\(index)")) }
            await clock.waitForSleepers(atLeast: 1)
            clock.advance(by: .milliseconds(360))
            let finished = await completes(task)
            paths.append(try XCTUnwrap(finished).path)
        }
        let third = await completes(Task { await engine.decide(Fixture.request("cold-2")) })
        paths.append(try XCTUnwrap(third, "an open breaker answers without waiting").path)
        XCTAssertEqual(paths, [.fallback(.featuresTimedOut), .fallback(.featuresTimedOut), .fallback(.breakerOpen)])
        XCTAssertEqual(remote.calls, 2, "the third request never touched the hung remote")
        remote.release()
    }

    func testExhaustedBudgetSkipsTheRemote() async throws {
        let clock = ManualClock(now: .seconds(1))
        let remote = GatedSource(result: nil)
        let engine = try makeEngine(clock: clock, store: FeatureStore(), remote: remote)
        // Arrived 400 ms ago (queued behind something): the 360 ms lookup slice is already gone.
        let finished = await completes(Task { await engine.decide(Fixture.request("cold-1"), receivedAt: .milliseconds(600)) })
        let decision = try XCTUnwrap(finished, "an exhausted request must not wait for anything")
        XCTAssertEqual(decision.path, .fallback(.budgetExhausted))
        XCTAssertEqual(remote.calls, 0)
        remote.release()
    }

    /// README decision 9: an exhausted request must not consume the breaker's single half-open probe.
    func testExhaustedRequestDoesNotConsumeTheHalfOpenProbe() async throws {
        let clock = ManualClock(now: .seconds(1))
        let remote = FlakySource(failures: 1, result: Fixture.loyalFeatures("cold-2"))
        let engine = try makeEngine(clock: clock, store: FeatureStore(), remote: remote, configuration: Fixture.configuration(breakerFailureThreshold: 1))
        let failed = await engine.decide(Fixture.request("cold-1"), receivedAt: clock.now())
        XCTAssertEqual(failed.path, .fallback(.featuresFailed))
        XCTAssertEqual(engine.breaker.currentState, .open(until: .seconds(6)))
        clock.advance(by: .seconds(6))  // the open window has passed: the next attempt is the probe
        let exhausted = await engine.decide(Fixture.request("cold-2"), receivedAt: clock.now() - .milliseconds(445))
        XCTAssertEqual(exhausted.path, .fallback(.budgetExhausted))
        XCTAssertEqual(remote.calls, 1, "the exhausted request never called the remote")
        let probe = await engine.decide(Fixture.request("cold-2"), receivedAt: clock.now())
        XCTAssertEqual(probe.path, .personalized, "the probe was still available, succeeded, and closed the breaker")
        XCTAssertEqual(remote.calls, 2)
        XCTAssertEqual(engine.breaker.currentState, .closed(consecutiveFailures: 0))
    }

    func testUnknownProductDefersToApple() async throws {
        let engine = try makeEngine(clock: ManualClock())
        let decision = await engine.decide(Fixture.request("loyal-1", product: "not-in-catalog"))
        XCTAssertEqual(decision.path, .deferToApple)
        XCTAssertNil(decision.response)
    }

    func testLocaleFallsBackAlongTheChain() async throws {
        let engine = try makeEngine(clock: ManualClock())
        let decision = await engine.decide(Fixture.request("loyal-1", locale: "en_GB"))
        XCTAssertEqual(decision.resolvedLocale, "en-US")
        XCTAssertTrue(decision.notes.contains(.localeFallback))
    }

    func testSequentialDuplicateIsReplayedEvenIfAFreshDecisionWouldDiffer() async throws {
        let log = RingBufferDecisionLog(capacity: 10)
        let store = Fixture.store(with: ["loyal-1"])
        let engine = try makeEngine(clock: ManualClock(), store: store, sink: log)
        let first = await engine.decide(Fixture.request("loyal-1", requestIdentifier: "req-1"))
        XCTAssertEqual(first.response?.messageIdentifier, Fixture.offerMessage)
        // Between the original and its duplicate, the subscriber redeems an offer: deciding afresh
        // would now say "switch plan". The duplicate must still get the original answer, byte for byte.
        store.ingest(SubscriptionFact(notificationUUID: "late-redeem", signedDate: Fixture.now, originalTransactionId: "loyal-1", productId: nil, kind: .offerRedeemed(offerId: "x")))
        let fresh = await engine.decide(Fixture.request("loyal-1", requestIdentifier: "req-2"))
        XCTAssertEqual(fresh.response?.messageIdentifier, Fixture.switchMessage, "control: a fresh decision does change")
        // A re-signed copy (later signedDate) of the same request must not defeat idempotency.
        let duplicate = await engine.decide(Fixture.request("loyal-1", requestIdentifier: "req-1", signedDate: Fixture.now + 900))
        XCTAssertEqual(duplicate.path, .replayed(originalDecisionId: first.decisionId))
        XCTAssertEqual(try duplicate.response?.jsonData(), try first.response?.jsonData())
        XCTAssertEqual(duplicate.decisionId, first.decisionId)
        let runs = await engine.pipelineRuns
        let replays = await engine.replays
        XCTAssertEqual(runs, 2)
        XCTAssertEqual(replays, 1)
        XCTAssertEqual(log.records().map(\.isReplay), [false, false, true])
    }

    func testConcurrentDuplicatesShareOnePipelineRun() async throws {
        let clock = ManualClock()
        let remote = GatedSource(result: Fixture.loyalFeatures("cold-1"))
        let engine = try makeEngine(clock: clock, store: FeatureStore(), remote: remote)
        let request = Fixture.request("cold-1", requestIdentifier: "dup")
        let first = Task { await engine.decide(request) }
        let started = await waitUntil { remote.calls == 1 }
        XCTAssertTrue(started)
        let inFlight = await engine.inFlightCount
        XCTAssertEqual(inFlight, 1)
        let second = Task { await engine.decide(request) }
        for _ in 0..<2_000 { await Task.yield() }
        remote.release()
        let aResult = await completes(first)
        let a = try XCTUnwrap(aResult)
        let bResult = await completes(second)
        let b = try XCTUnwrap(bResult)
        XCTAssertEqual(remote.calls, 1, "the duplicate must not start a second lookup")
        XCTAssertEqual(a.response, b.response)
        let runs = await engine.pipelineRuns
        XCTAssertEqual(runs, 1)
        let replayed = [a.path, b.path].filter { if case .replayed = $0 { return true } else { return false } }
        XCTAssertEqual(replayed.count, 1)
    }

    func testSameIdentifierForADifferentSubscriberIsNotReplayed() async throws {
        let engine = try makeEngine(clock: ManualClock(), store: Fixture.store(with: ["loyal-1", "loyal-2"]))
        _ = await engine.decide(Fixture.request("loyal-1", requestIdentifier: "shared"))
        let other = await engine.decide(Fixture.request("loyal-2", requestIdentifier: "shared"))
        XCTAssertEqual(other.path, .personalized)
        let runs = await engine.pipelineRuns
        XCTAssertEqual(runs, 2)
        XCTAssertNotEqual(
            Decision.identifier(for: Fixture.request("loyal-1", requestIdentifier: "shared")), other.decisionId,
            "two different requests sharing an identifier are two decisions to attribution"
        )
        XCTAssertEqual(
            Decision.identifier(for: Fixture.request("loyal-2", requestIdentifier: "shared", signedDate: Fixture.now + 900)), other.decisionId,
            "a re-signed duplicate is the same decision"
        )
    }

    /// An arrival older than Apple's timeout is charged as exactly that old: the request is already
    /// lost, and the floor keeps every duration sum far from overflow whatever a caller passes.
    func testArrivalOlderThanAppleTimeoutIsClamped() async throws {
        let clock = ManualClock(now: .seconds(100))
        let engine = try makeEngine(clock: clock, store: FeatureStore(), remote: GatedSource(result: nil))
        let finished = await completes(Task { await engine.decide(Fixture.request("cold-1"), receivedAt: .seconds(90)) })
        let decision = try XCTUnwrap(finished)
        XCTAssertEqual(decision.path, .fallback(.budgetExhausted))
        XCTAssertEqual(decision.timings.total, EngineConfiguration.appleTimeout)
        let ancient = await completes(Task { await engine.decide(Fixture.request("cold-2"), receivedAt: .seconds(-Int64.max / 2)) })
        XCTAssertEqual(try XCTUnwrap(ancient).timings.total, EngineConfiguration.appleTimeout)
    }

    func testReplayCacheIsBounded() async throws {
        let engine = try makeEngine(clock: ManualClock(), configuration: Fixture.configuration(replayCapacity: 2))
        for index in 0..<5 { _ = await engine.decide(Fixture.request("loyal-1", requestIdentifier: "r\(index)")) }
        let again = await engine.decide(Fixture.request("loyal-1", requestIdentifier: "r0"))
        XCTAssertEqual(again.path, .personalized, "evicted, so decided afresh")
        let recent = await engine.decide(Fixture.request("loyal-1", requestIdentifier: "r4"))
        XCTAssertEqual(recent.path, .replayed(originalDecisionId: Decision.identifier(for: Fixture.request("loyal-1", requestIdentifier: "r4"))))
    }

    enum Latency: CustomStringConvertible {
        case instant, after(Int), hung
        var description: String {
            switch self {
            case .instant: return "instant"
            case .after(let ms): return "\(ms)ms"
            case .hung: return "hung"
            }
        }
    }

    /// Drives a manual clock 1 ms at a time, advancing only once every live task is parked on it.
    func driveUntilDelivered(_ clock: ManualClock, _ task: Task<Decision, Never>, delivered: Locked<Duration?>) async {
        for _ in 0..<2_000 {
            if delivered.withLock({ $0 }) != nil { return }
            var stable = 0
            var last = -1
            while stable < 50 {
                await Task.yield()
                if delivered.withLock({ $0 }) != nil { return }
                let count = clock.sleeperCount
                stable = count == last ? stable + 1 : 0
                last = count
            }
            // Work may be running on other threads; give it a moment of real time before moving the clock.
            try? await Task.sleep(for: .microseconds(300))
            if delivered.withLock({ $0 }) != nil { return }
            if clock.sleeperCount > 0 { clock.advance(by: .milliseconds(1)) }
        }
    }

    /// The headline invariant across every combination of a local or remote subscriber, remote
    /// latency either side of the 360 ms lookup deadline, and signer latency either side of the
    /// 440 ms signing deadline — each dependency either cooperative (sleeps on the clock) or hung
    /// and deaf to cancellation. For each, the outcome is predicted and the instant the decision is
    /// *delivered* (read from the clock, not from the engine's own timings) must be inside the budget.
    func testNeverLaterThanTheBudgetAcrossDeadlineBoundaries() async throws {
        let configuration = Fixture.configuration()
        let lookupDeadline = 360
        let signingDeadline = 440
        let remotes: [Latency] = [.instant, .after(200), .after(355), .after(365), .hung]
        let signers: [Latency] = [.instant, .after(150), .after(235), .after(245), .after(435), .after(445), .hung]
        var scenarios: [(cold: Bool, remote: Latency, signer: Latency)] = []
        for signer in signers { scenarios.append((false, .instant, signer)) }
        for remote in remotes { for signer in signers { scenarios.append((true, remote, signer)) } }
        XCTAssertEqual(scenarios.count, 42)

        for (cold, remote, signer) in scenarios {
            let label = "cold=\(cold) remote=\(remote) signer=\(signer)"
            let clock = ManualClock()
            let id = cold ? "cold-x" : "warm-x"
            let features = Fixture.loyalFeatures(id)
            let hungRemote = GatedSource(result: features)
            let hungSigner = GatedSigner()
            let remoteSource: any FeatureSource
            switch remote {
            case .instant: remoteSource = ImmediateSource(result: features)
            case .after(let ms): remoteSource = ClockedSource(clock: clock, latency: .milliseconds(ms), result: features)
            case .hung: remoteSource = hungRemote
            }
            let offerSigner: any OfferSigner
            switch signer {
            case .instant: offerSigner = InstantSigner()
            case .after(let ms): offerSigner = ClockedSigner(clock: clock, latency: .milliseconds(ms))
            case .hung: offerSigner = hungSigner
            }
            let store = cold ? FeatureStore() : Fixture.store(with: [id])
            let engine = try makeEngine(clock: clock, store: store, remote: remoteSource, signer: offerSigner, configuration: configuration)
            let delivered = Locked<Duration?>(nil)
            let task = Task {
                let decision = await engine.decide(Fixture.request(id), receivedAt: clock.now())
                delivered.withLock { $0 = clock.now() }
                return decision
            }
            await driveUntilDelivered(clock, task, delivered: delivered)
            let finished = await completes(task)
            let decision = try XCTUnwrap(finished, "\(label): never delivered")
            let at = try XCTUnwrap(delivered.withLock { $0 })
            XCTAssertLessThanOrEqual(at, configuration.responseBudget, label)
            XCTAssertLessThanOrEqual(decision.timings.total, at, "\(label): the engine's own timing never exceeds delivery")

            // Predict the outcome.
            let lookupEnd: Int?
            switch (cold, remote) {
            case (false, _): lookupEnd = 0
            case (true, .instant): lookupEnd = 0
            case (true, .after(let ms)): lookupEnd = ms < lookupDeadline ? ms : nil
            case (true, .hung): lookupEnd = nil
            }
            guard let start = lookupEnd else {
                XCTAssertEqual(decision.path, .fallback(.featuresTimedOut), label)
                XCTAssertEqual(decision.timings.total, .milliseconds(lookupDeadline), "\(label): timed out exactly at the lookup deadline")
                hungRemote.release()
                hungSigner.release()
                continue
            }
            let signedBy: Int?
            switch signer {
            case .instant: signedBy = start
            case .after(let ms): signedBy = start + ms < signingDeadline ? start + ms : nil
            case .hung: signedBy = nil
            }
            if let signedAt = signedBy {
                guard case .promotionalOffer? = decision.response else { XCTFail("\(label): expected an offer, got \(decision.path)"); continue }
                // The clock can be at most a tick past the predicted instant (work finishing on another thread).
                XCTAssertGreaterThanOrEqual(decision.timings.total, .milliseconds(signedAt), label)
                XCTAssertLessThanOrEqual(decision.timings.total, .milliseconds(signedAt + 2), label)
            } else {
                XCTAssertEqual(decision.response, .alternateProduct(messageIdentifier: Fixture.switchMessage, productId: Fixture.lite), label)
                XCTAssertTrue(decision.notes.contains(.offerSigningTimedOut), label)
                XCTAssertEqual(decision.timings.total, .milliseconds(signingDeadline), "\(label): degraded exactly at the signing deadline")
            }
            hungRemote.release()
            hungSigner.release()
        }
    }
}
