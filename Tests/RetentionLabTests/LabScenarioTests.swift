import RetentionAttribution
import RetentionCopy
import RetentionEngine
import XCTest
@testable import RetentionLab

/// The demo app's scenarios, run against the real engine. These are what the README and the
/// screenshots promise, checked by code rather than by reading the view.
final class LabScenarioTests: XCTestCase {
    static let configuration = EngineConfiguration(
        appAppleId: 6_500_000_001,
        environment: .production,
        experiment: ExperimentAssigner(salt: "retention-2026-11", holdoutBasisPoints: 1_000),
        offerPolicy: OfferPolicy(coolDownMilliseconds: 60 * 86_400_000, maxRedemptionsInWindow: 2, windowMilliseconds: 365 * 86_400_000)
    )

    func makeRig(_ faults: LabFaults = LabFaults()) async throws -> LabRig {
        LabRig(world: try await LabWorld.make(configuration: Self.configuration), faults: faults)
    }

    func persona(_ id: String, in rig: LabRig) throws -> LabPersona {
        try XCTUnwrap(rig.world.personas.first { $0.id == id })
    }

    func testWorldIsDeterministicAndCompiledByTheOfflinePipeline() async throws {
        let a = try await LabWorld.make(configuration: Self.configuration)
        // Pinned, and cross-checked with an independent FNV-1a implementation: the personas'
        // identifiers are found by scanning for the arm each persona needs under this salt.
        XCTAssertEqual(a.personas.map(\.originalTransactionId), ["2000001000", "2000002000", "2000003000", "2000004000", "cold-sam", "2000005000"])
        XCTAssertGreaterThan(a.catalog.entryCount, 40)
        XCTAssertFalse(a.pipelineReport.rejected.isEmpty, "the scripted drafter's known mistakes are rejected")
        XCTAssertFalse(a.compileResult.awaitingApproval.isEmpty, "some copy is still in App Review")
        XCTAssertFalse(a.compileResult.uploads.isEmpty, "some copy Apple has never seen is planned for upload")
        XCTAssertEqual(a.personas.map(\.id), ["maya", "lea", "jonas", "kenji", "sam", "priya"])
        let assigner = Self.configuration.experiment
        XCTAssertEqual(assigner.arm(for: a.personas[0].originalTransactionId), .treatment)
        XCTAssertEqual(assigner.arm(for: a.personas[5].originalTransactionId), .holdout)
    }

    /// The default state of the demo: one tap shows a personalized, signed offer.
    func testDefaultPersonaGetsAPersonalizedSignedOffer() async throws {
        let rig = try await makeRig()
        let run = await rig.simulateCancellation(persona: try persona("maya", in: rig))
        XCTAssertEqual(run.response.status, 200)
        XCTAssertEqual(run.response.decision?.path, .personalized)
        guard case .promotionalOffer? = run.response.decision?.response else { return XCTFail("expected an offer") }
        XCTAssertEqual(run.offerLabel, "3 months at 50% off")
        XCTAssertEqual(run.actionTitle, "Accept Offer", "Apple's button label on the Confirm Cancellation page")
        XCTAssertNotNil(run.header)
        XCTAssertTrue(run.responseJSON.contains("promotionalOfferSignatureV2"))
    }

    func testEachPersonaTakesItsDocumentedPath() async throws {
        let rig = try await makeRig()
        let lea = await rig.simulateCancellation(persona: try persona("lea", in: rig))
        XCTAssertEqual(lea.response.decision?.segment, .trial)
        XCTAssertEqual(lea.response.decision?.resolvedLocale, "fr")
        XCTAssertTrue(lea.response.decision?.notes.contains(.localeFallback) ?? false)
        guard case .message? = lea.response.decision?.response else { return XCTFail("trial gets text, never an offer") }

        let jonas = await rig.simulateCancellation(persona: try persona("jonas", in: rig))
        XCTAssertTrue(jonas.response.decision?.notes.contains(.offerIneligible) ?? false)
        guard case .alternateProduct(_, let product)? = jonas.response.decision?.response else { return XCTFail("cool-down → switch plan") }
        XCTAssertEqual(product, LabWorld.liteMonthly)

        let kenji = await rig.simulateCancellation(persona: try persona("kenji", in: rig))
        XCTAssertEqual(kenji.response.decision?.segment, .billingRetry)
        XCTAssertTrue(kenji.body?.contains("お支払い") ?? false)

        let priya = await rig.simulateCancellation(persona: try persona("priya", in: rig))
        XCTAssertEqual(priya.response.decision?.path, .holdoutControl)

        let sam = await rig.simulateCancellation(persona: try persona("sam", in: rig))
        XCTAssertEqual(sam.response.decision?.notes.prefix(2), [.l1Miss, .l2Hit])
        XCTAssertEqual(sam.response.decision?.path, .personalized)
    }

    /// Real clock: a remote that hangs and ignores cancellation still yields an approved message
    /// inside the 450 ms budget (with scheduling slack), and well inside Apple's 700 ms.
    func testHungRemoteStillAnswersInsideTheBudget() async throws {
        let rig = try await makeRig(LabFaults(remote: .hung))
        let run = await rig.simulateCancellation(persona: try persona("sam", in: rig))
        XCTAssertEqual(run.response.status, 200)
        XCTAssertEqual(run.response.decision?.path, .fallback(.featuresTimedOut))
        // Real clock: the lookup is cut at 360 ms; the engine's own measurement must be inside the 450 ms budget.
        let total = try XCTUnwrap(run.response.decision?.timings.total)
        XCTAssertGreaterThanOrEqual(total, .milliseconds(360))
        XCTAssertLessThan(total, Self.configuration.responseBudget)
        XCTAssertNotNil(run.header, "the safe fallback is real, approved copy")
    }

    func testSlowSignerDegradesAndWrongAppIsRefused() async throws {
        let rig = try await makeRig(LabFaults(signer: .slow))
        let slow = await rig.simulateCancellation(persona: try persona("maya", in: rig))
        XCTAssertTrue(slow.response.decision?.notes.contains(.offerSigningTimedOut) ?? false)
        // The signer is cut at 440 ms. On a real clock the timer can fire a few milliseconds late
        // (the exact boundary is proven on a manual clock in DecisionEngineTests), so allow 30 ms.
        let total = try XCTUnwrap(slow.response.decision?.timings.total)
        XCTAssertGreaterThanOrEqual(total, .milliseconds(440))
        XCTAssertLessThan(total, Self.configuration.responseBudget + .milliseconds(30))
        rig.setFaults(LabFaults(wrongAppAppleId: true))
        let wrong = await rig.simulateCancellation(persona: try persona("maya", in: rig))
        XCTAssertEqual(wrong.response.status, 403)
        XCTAssertNil(wrong.header)
    }

    func testDuplicateDeliveryRunsThePipelineOnce() async throws {
        let rig = try await makeRig(LabFaults(duplicateDelivery: true))
        let run = await rig.simulateCancellation(persona: try persona("maya", in: rig))
        let duplicate = try XCTUnwrap(run.duplicate)
        XCTAssertEqual(duplicate.body, run.response.body)
        guard case .replayed? = duplicate.decision?.path else { return XCTFail("expected a replay") }
        let runs = await rig.engine.pipelineRuns
        XCTAssertEqual(runs, 1)
    }

    func testSmallLoadComparisonNeverAnswersLaterThanApple() async throws {
        let world = try await LabWorld.make(configuration: Self.configuration)
        let comparison = await LabRig.runLoadComparison(world: world, requests: 160, ratePerSecond: 400, closedLoopWorkers: 4, stall: .milliseconds(200))
        XCTAssertEqual(comparison.openLoop.requests, 160)
        XCTAssertEqual(comparison.closedLoop.requests, 160)
        XCTAssertEqual(comparison.openLoop.lateAgainstApple, 0, "nothing answers later than Apple's 700 ms")
        // Arrival is stamped at the intended start, so a request that queued behind the stall gets only
        // what is left of its budget: the slowest answer stays inside 450 ms instead of stall + lookup.
        let slowest = try XCTUnwrap(comparison.openLoop.fromIntendedStart.quantile(1.0))
        XCTAssertLessThan(slowest, Self.configuration.responseBudget, "queueing behind the stall is charged to the budget")
        XCTAssertGreaterThan(comparison.readout.treatment.resolvedSubscribers, 50)
        XCTAssertGreaterThan(comparison.readout.holdout.resolvedSubscribers, 0, "holdout decisions reach the readout")
        XCTAssertNotNil(comparison.readout.preventedCancellations, "so the headline comparison exists")
    }

    func testLaunchOptionsParsing() {
        let options = LabLaunchOptions(arguments: ["Demo", "-tab", "load", "-autoplay", "1", "-persona", "sam", "-remote", "hung", "-signer", "slow", "-bogus"])
        XCTAssertEqual(options.tab, .load)
        XCTAssertTrue(options.autoplay)
        XCTAssertEqual(options.personaID, "sam")
        XCTAssertEqual(options.remote, .hung)
        XCTAssertEqual(options.signer, .slow)
        let defaults = LabLaunchOptions(arguments: ["-tab", "nonsense", "-autoplay"])
        XCTAssertEqual(defaults.tab, .decide)
        XCTAssertFalse(defaults.autoplay)
    }
}
