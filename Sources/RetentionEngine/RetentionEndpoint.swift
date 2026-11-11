import Foundation

/// Why the endpoint answered with something other than `200`.
///
/// Every non-`200` answer makes Apple fall back to the message configured in App Store Connect
/// or to the default message for the product and locale. That is the right outcome whenever the
/// request cannot be trusted or there is nothing approved to say.
public enum EndpointRejection: String, Codable, Sendable, Hashable, CaseIterable {
    case payloadTooLarge
    case malformedBody
    case malformedSignedPayload
    case signatureInvalid
    case verificationTimedOut
    case malformedPayload
    /// Apple: "If it doesn't match, don't respond to the request."
    case appAppleIdMismatch
    case environmentMismatch
    case noApprovedMessage
    case encodingFailed

    public var status: Int {
        switch self {
        case .payloadTooLarge: return 413
        case .malformedBody, .malformedSignedPayload, .malformedPayload: return 400
        case .signatureInvalid: return 401
        case .appAppleIdMismatch, .environmentMismatch: return 403
        case .noApprovedMessage: return 404
        case .verificationTimedOut: return 503
        case .encodingFailed: return 500
        }
    }
}

public struct EndpointResponse: Sendable, Hashable {
    public let status: Int
    /// The JSON `RealtimeResponseBody` for a `200`; empty otherwise.
    public let body: Data
    public let decision: Decision?
    public let rejection: EndpointRejection?
    public let elapsed: Duration
}

/// Framework-agnostic adapter for the Get Retention Message endpoint: request bytes in,
/// status and response bytes out. Mount it in Vapor, Hummingbird or a Lambda handler with a
/// few lines; the kit takes no server-framework dependency.
public struct RetentionEndpoint: Sendable {
    public let engine: DecisionEngine
    private let verifier: any SignedPayloadVerifier
    /// Always the engine's clock: one clock for every deadline, by construction.
    private var clock: any DeadlineClock { engine.clock }

    public init(engine: DecisionEngine, verifier: any SignedPayloadVerifier) {
        self.engine = engine
        self.verifier = verifier
    }

    /// - Parameter receivedAt: Arrival time on `engine.clock` (stamp it as early as you can).
    ///   Defaults to now.
    public func handle(body: Data, receivedAt: Duration? = nil) async -> EndpointResponse {
        let start = DecisionEngine.clampArrival(receivedAt, now: clock.now())
        let configuration = engine.configuration

        guard body.count <= configuration.maxRequestBytes else {
            return reject(.payloadTooLarge, start: start)
        }
        guard let envelope = try? JSONDecoder().decode(RealtimeRequestBody.self, from: body) else {
            return reject(.malformedBody, start: start)
        }
        guard let jws = try? CompactJWS(parsing: envelope.signedPayload) else {
            return reject(.malformedSignedPayload, start: start)
        }

        // Verification gets its own slice from when it starts, but never past the overall budget: a
        // request that queued behind a stall still gets verified if there is time left, and is
        // refused (Apple shows its fallback) if there is none.
        let verificationDeadline = min(
            clock.now() + configuration.verificationBudget,
            start + configuration.responseBudget - configuration.finalizeReserve
        )
        let verifier = self.verifier
        let verification = await raceDeadline(verificationDeadline, on: clock) {
            try await verifier.verifiedPayload(of: jws)
        }
        let payload: Data
        switch verification {
        case .value(let data): payload = data
        case .timedOut, .cancelled: return reject(.verificationTimedOut, start: start)
        case .failed: return reject(.signatureInvalid, start: start)
        }

        guard let request = try? JSONDecoder().decode(DecodedRealtimeRequest.self, from: payload) else {
            return reject(.malformedPayload, start: start)
        }
        guard request.appAppleId == configuration.appAppleId else {
            return reject(.appAppleIdMismatch, start: start)
        }
        guard request.environment == configuration.environment else {
            return reject(.environmentMismatch, start: start)
        }

        let decision = await engine.decide(request, receivedAt: start)
        guard let response = decision.response else {
            return reject(.noApprovedMessage, start: start, decision: decision)
        }
        guard let data = try? response.jsonData() else {
            return reject(.encodingFailed, start: start, decision: decision)
        }
        return EndpointResponse(status: 200, body: data, decision: decision, rejection: nil, elapsed: clock.now() - start)
    }

    private func reject(_ rejection: EndpointRejection, start: Duration, decision: Decision? = nil) -> EndpointResponse {
        EndpointResponse(
            status: rejection.status,
            body: Data(),
            decision: decision,
            rejection: rejection,
            elapsed: clock.now() - start
        )
    }
}
