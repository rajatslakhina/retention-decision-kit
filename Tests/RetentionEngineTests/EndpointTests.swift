import XCTest
@testable import RetentionEngine

struct RejectingVerifier: SignedPayloadVerifier {
    struct BadSignature: Error {}
    func verifiedPayload(of jws: CompactJWS) async throws -> Data { throw BadSignature() }
}

struct GatedVerifier: SignedPayloadVerifier {
    let gate = GatedSource(result: nil)
    func verifiedPayload(of jws: CompactJWS) async throws -> Data {
        _ = try await gate.features(for: "verify")
        return jws.payload
    }
}

final class EndpointTests: XCTestCase {
    func makeEndpoint(clock: ManualClock = ManualClock(), verifier: any SignedPayloadVerifier = InsecureAcceptAnyVerifier()) throws -> RetentionEndpoint {
        let engine = DecisionEngine(
            configuration: Fixture.configuration(),
            catalog: CatalogHolder(try Fixture.catalog()),
            store: Fixture.store(with: ["loyal-1"]),
            signer: InstantSigner(),
            clock: clock
        )
        return RetentionEndpoint(engine: engine, verifier: verifier)
    }

    func body(for request: DecodedRealtimeRequest) throws -> Data {
        try JSONEncoder().encode(RealtimeRequestBody(signedPayload: try CompactJWS.unsignedFixture(request)))
    }

    func testHappyPathReturnsAppleShapedJSON() async throws {
        let endpoint = try makeEndpoint()
        let response = await endpoint.handle(body: try body(for: Fixture.request("loyal-1")))
        XCTAssertEqual(response.status, 200)
        XCTAssertNil(response.rejection)
        let decoded = try JSONDecoder().decode(RealtimeResponse.self, from: response.body)
        XCTAssertEqual(decoded.messageIdentifier, Fixture.offerMessage)
    }

    func testMalformedInputsAreRejectedBeforeTheEngine() async throws {
        let endpoint = try makeEndpoint()
        let oversize = await endpoint.handle(body: Data(repeating: 0x20, count: 70 * 1_024))
        XCTAssertEqual(oversize.rejection, .payloadTooLarge)
        XCTAssertEqual(oversize.status, 413)
        let notJSON = await endpoint.handle(body: Data("nope".utf8))
        XCTAssertEqual(notJSON.rejection, .malformedBody)
        let badJWS = await endpoint.handle(body: try JSONEncoder().encode(RealtimeRequestBody(signedPayload: "x.y")))
        XCTAssertEqual(badJWS.rejection, .malformedSignedPayload)
        let wrongShape = await endpoint.handle(body: try JSONEncoder().encode(RealtimeRequestBody(signedPayload: try CompactJWS.unsignedFixture(["hello": "world"]))))
        XCTAssertEqual(wrongShape.rejection, .malformedPayload)
        XCTAssertEqual(wrongShape.status, 400)
        let runs = await endpoint.engine.pipelineRuns
        XCTAssertEqual(runs, 0)
    }

    func testSignatureFailureIs401() async throws {
        let endpoint = try makeEndpoint(verifier: RejectingVerifier())
        let response = await endpoint.handle(body: try body(for: Fixture.request()))
        XCTAssertEqual(response.status, 401)
        XCTAssertTrue(response.body.isEmpty)
    }

    func testSlowVerificationTimesOutWithinItsSlice() async throws {
        let clock = ManualClock()
        let verifier = GatedVerifier()
        let endpoint = try makeEndpoint(clock: clock, verifier: verifier)
        let payload = try body(for: Fixture.request())
        let task = Task { await endpoint.handle(body: payload) }
        await clock.waitForSleepers(atLeast: 1)
        clock.advance(by: .milliseconds(60))
        let finished = await completes(task)
        let response = try XCTUnwrap(finished, "verification ignored its deadline")
        XCTAssertEqual(response.rejection, .verificationTimedOut)
        XCTAssertEqual(response.status, 503)
        verifier.gate.release()
    }

    /// A request that queued for 300 ms before the handler ran still has 140 ms of budget: its
    /// verification slice is measured from when verification starts, capped by what's left.
    func testLateArrivalIsStillVerifiedWhileBudgetRemains() async throws {
        let clock = ManualClock(now: .seconds(10))
        let endpoint = try makeEndpoint(clock: clock)
        let response = await endpoint.handle(body: try body(for: Fixture.request("loyal-1")), receivedAt: .seconds(10) - .milliseconds(300))
        XCTAssertEqual(response.status, 200)
        let exhausted = await endpoint.handle(body: try body(for: Fixture.request("loyal-1")), receivedAt: .seconds(10) - .milliseconds(445))
        XCTAssertEqual(exhausted.rejection, .verificationTimedOut, "no budget left: refuse rather than answer late")
    }

    /// README decision 1: arrival is charged to the budget. A request that arrived 300 ms ago has
    /// 60 ms of lookup left, so a hung remote is cut at arrival + 360 ms, not at now + 360 ms.
    func testArrivalTimeIsChargedToTheEngineBudget() async throws {
        let clock = ManualClock(now: .seconds(10))
        let remote = GatedSource(result: nil)
        let engine = DecisionEngine(
            configuration: Fixture.configuration(),
            catalog: CatalogHolder(try Fixture.catalog()),
            store: FeatureStore(),
            remote: remote,
            signer: InstantSigner(),
            clock: clock
        )
        let endpoint = RetentionEndpoint(engine: engine, verifier: InsecureAcceptAnyVerifier())
        let requestBody = try body(for: Fixture.request("cold-1"))
        let task = Task { await endpoint.handle(body: requestBody, receivedAt: .seconds(10) - .milliseconds(300)) }
        var spins = 0
        while remote.calls == 0, spins < 200_000 {
            spins += 1
            await Task.yield()
        }
        XCTAssertEqual(remote.calls, 1)
        await clock.waitForSleepers(atLeast: 1)
        clock.advance(by: .milliseconds(60))
        let finished = await completes(task, within: 5)
        let response = try XCTUnwrap(finished, "the lookup must be cut 360 ms after arrival")
        XCTAssertEqual(response.decision?.path, .fallback(.featuresTimedOut))
        XCTAssertEqual(response.decision?.timings.total, .milliseconds(360))
        remote.release()
    }

    func testOtherAppsAndEnvironmentsGetNoMessage() async throws {
        let endpoint = try makeEndpoint()
        let otherApp = await endpoint.handle(body: try body(for: Fixture.request(appAppleId: 42)))
        XCTAssertEqual(otherApp.rejection, .appAppleIdMismatch)
        XCTAssertEqual(otherApp.status, 403)
        XCTAssertTrue(otherApp.body.isEmpty)
        let sandbox = await endpoint.handle(body: try body(for: Fixture.request(environment: .sandbox)))
        XCTAssertEqual(sandbox.rejection, .environmentMismatch)
        let runs = await endpoint.engine.pipelineRuns
        XCTAssertEqual(runs, 0, "neither reached the engine")
    }

    func testNothingApprovedDefersToApple() async throws {
        let endpoint = try makeEndpoint()
        let response = await endpoint.handle(body: try body(for: Fixture.request(product: "unknown")))
        XCTAssertEqual(response.status, 404)
        XCTAssertEqual(response.decision?.path, .deferToApple)
    }
}
