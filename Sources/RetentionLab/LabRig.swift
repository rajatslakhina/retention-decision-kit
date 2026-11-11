import Dispatch
import Foundation
import RetentionAttribution
import RetentionCopy
import RetentionEngine

/// How the remote feature source behaves.
public enum RemoteLatency: String, CaseIterable, Sendable, Hashable, Identifiable {
    case fast, slow, beyondBudget, hung
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .fast: return "8 ms"
        case .slow: return "140 ms"
        case .beyondBudget: return "900 ms"
        case .hung: return "Hangs"
        }
    }
}

/// How the offer signer behaves.
public enum SignerBehavior: String, CaseIterable, Sendable, Hashable, Identifiable {
    case healthy, slow, failing
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .healthy: return "12 ms"
        case .slow: return "700 ms"
        case .failing: return "Fails"
        }
    }
}

public struct LabFaults: Sendable, Hashable {
    public var remote: RemoteLatency
    public var signer: SignerBehavior
    /// Deliver the same request twice, concurrently — a duplicate delivery racing the original.
    public var duplicateDelivery: Bool
    /// Send a request for someone else's app.
    public var wrongAppAppleId: Bool

    public init(remote: RemoteLatency = .fast, signer: SignerBehavior = .healthy, duplicateDelivery: Bool = false, wrongAppAppleId: Bool = false) {
        self.remote = remote
        self.signer = signer
        self.duplicateDelivery = duplicateDelivery
        self.wrongAppAppleId = wrongAppAppleId
    }
}

/// Waits without honouring cancellation — the behaviour of a blocking driver or a lost continuation.
/// The race in the engine has to cope with exactly this.
func uncooperativeWait(_ duration: Duration) async {
    let nanoseconds = UInt64(clamping: max(0, Saturating.multiply(Saturating.milliseconds(duration), 1_000_000)))
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(clamping: nanoseconds))) {
            continuation.resume()
        }
    }
}

struct LabRemoteSource: FeatureSource {
    let faults: Locked<LabFaults>

    func features(for originalTransactionId: String) async throws -> SubscriberFeatures? {
        let behaviour = LabRig.remoteLatency(encodedIn: originalTransactionId) ?? faults.withLock { $0.remote }
        switch behaviour {
        case .fast: try await Task.sleep(for: .milliseconds(8))
        case .slow: try await Task.sleep(for: .milliseconds(140))
        case .beyondBudget: try await Task.sleep(for: .milliseconds(900))
        case .hung: await uncooperativeWait(.seconds(3))
        }
        guard originalTransactionId.hasPrefix("cold-") else { return nil }
        return LabWorld.coldFeatures(for: originalTransactionId)
    }
}

struct LabSigner: OfferSigner {
    let faults: Locked<LabFaults>

    struct SigningFailed: Error {}

    func signatureV2(productId: String, offerId: String, originalTransactionId: String) async throws -> String {
        switch faults.withLock({ $0.signer }) {
        case .healthy: try await Task.sleep(for: .milliseconds(12))
        case .slow: try await Task.sleep(for: .milliseconds(700))
        case .failing: throw SigningFailed()
        }
        // A stand-in for a real ES256 JWS: recognisable, never valid.
        let claims = "{\"offerIdentifier\":\"\(offerId)\",\"productId\":\"\(productId)\",\"transactionId\":\"\(originalTransactionId)\"}"
        return "demo-unsigned." + CompactJWS.encodeBase64URL(Data(claims.utf8)) + ".signature"
    }
}

/// One simulated trip through Apple's cancellation flow.
public struct LabRun: Sendable {
    public let persona: LabPersona
    public let response: EndpointResponse
    /// The duplicate delivery's response, when that fault is on.
    public let duplicate: EndpointResponse?
    public let requestJSON: String
    public let responseJSON: String
    /// What the subscriber would see.
    public let header: String?
    public let body: String?
    /// The button Apple shows with the message ("Accept Offer", "Switch Plan"), if any.
    public let actionTitle: String?
    /// What that button gets the subscriber.
    public let offerLabel: String?
}

public struct LoadComparison: Sendable {
    public let openLoop: LoadReport
    public let closedLoop: LoadReport
    public let readout: ExperimentReadout
    public let stall: Duration
    public let requests: Int
}

/// The running system: engine, endpoint, store, fakes and fault switches.
public final class LabRig: Sendable {
    public let world: LabWorld
    public let engine: DecisionEngine
    public let endpoint: RetentionEndpoint
    public let store: FeatureStore
    public let log: RingBufferDecisionLog
    private let faults: Locked<LabFaults>
    private let clock: SystemDeadlineClock
    private let sequence = Locked(0)
    private let lastRequestBody = Locked<Data?>(nil)

    public init(world: LabWorld, faults: LabFaults = LabFaults(), logCapacity: Int = 10_000) {
        let clock = SystemDeadlineClock()
        let faultBox = Locked(faults)
        let store = FeatureStore()
        store.ingest(world.seedFacts)
        let log = RingBufferDecisionLog(capacity: logCapacity)
        let engine = DecisionEngine(
            configuration: world.configuration,
            catalog: CatalogHolder(world.catalog),
            store: store,
            remote: LabRemoteSource(faults: faultBox),
            signer: LabSigner(faults: faultBox),
            sink: log,
            clock: clock
        )
        self.world = world
        self.engine = engine
        self.endpoint = RetentionEndpoint(engine: engine, verifier: InsecureAcceptAnyVerifier())
        self.store = store
        self.log = log
        self.faults = faultBox
        self.clock = clock
    }

    public var currentFaults: LabFaults { faults.withLock { $0 } }
    public func setFaults(_ newValue: LabFaults) { faults.withLock { $0 = newValue } }

    /// Load-test identifiers carry their remote latency (`cold-load-…-slow`).
    static func remoteLatency(encodedIn identifier: String) -> RemoteLatency? {
        guard identifier.hasPrefix("cold-load-"), let suffix = identifier.split(separator: "-").last else { return nil }
        return RemoteLatency(rawValue: String(suffix))
    }

    func requestBody(for request: DecodedRealtimeRequest) throws -> Data {
        let envelope = RealtimeRequestBody(signedPayload: try CompactJWS.unsignedFixture(request))
        return try JSONEncoder().encode(envelope)
    }

    /// Sends one request through the endpoint, exactly as Apple's server would.
    public func simulateCancellation(persona: LabPersona) async -> LabRun {
        let currentFaults = self.currentFaults
        let n = sequence.withLock { value -> Int in
            value += 1
            return value
        }
        // A cold subscriber is cold every time: use a fresh identifier in the treatment arm.
        let originalTransactionId = persona.inLocalStore
            ? persona.originalTransactionId
            : LabWorld.identifier(prefix: "cold-sam-\(n)-", landingIn: .treatment, assigner: world.configuration.experiment)
        let request = DecodedRealtimeRequest(
            originalTransactionId: originalTransactionId,
            appAppleId: currentFaults.wrongAppAppleId ? world.configuration.appAppleId &+ 1 : world.configuration.appAppleId,
            productId: persona.productId,
            userLocale: persona.locale,
            requestIdentifier: StableHash.contentUUID("lab-request-\(n)-\(UUID().uuidString)"),
            environment: world.configuration.environment,
            signedDate: Saturating.add(LabWorld.epoch, Saturating.multiply(Int64(n), 1_000))
        )
        let body = (try? requestBody(for: request)) ?? Data()
        let endpoint = self.endpoint
        let response: EndpointResponse
        var duplicate: EndpointResponse?
        if currentFaults.duplicateDelivery {
            // Two unstructured tasks rather than `async let`: Swift 6.0's task allocator aborts on
            // this `async let` pair ("freed pointer was not the last allocation") on Linux.
            let first = Task { await endpoint.handle(body: body) }
            let second = Task { await endpoint.handle(body: body) }
            let a = await first.value
            let b = await second.value
            // Whichever ran the pipeline is "the" response; the other is the replay.
            let aIsReplay: Bool = { if case .replayed? = a.decision?.path { return true } else { return false } }()
            response = aIsReplay ? b : a
            duplicate = aIsReplay ? a : b
        } else {
            response = await endpoint.handle(body: body)
        }
        lastRequestBody.withLock { $0 = body }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let requestJSON = (try? encoder.encode(request)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let responseJSON: String
        if response.status == 200, let object = try? JSONSerialization.jsonObject(with: response.body),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            responseJSON = String(decoding: pretty, as: UTF8.self)
        } else {
            responseJSON = "HTTP \(response.status) — no body. Apple shows the App Store Connect message or the default message."
        }
        let messageId = response.decision?.response?.messageIdentifier
        let copy = messageId.flatMap { world.messageCopy[$0] }
        var actionTitle: String?
        var offerLabel: String?
        switch response.decision?.response {
        case .promotionalOffer?:
            actionTitle = "Accept Offer"
            offerLabel = "3 months at \(LabWorld.offerDiscountPercent)% off"
        case .alternateProduct(_, let product)?:
            actionTitle = "Switch Plan"
            offerLabel = "Switch to \(LabWorld.productName(product))"
        default:
            break
        }
        return LabRun(
            persona: persona,
            response: response,
            duplicate: duplicate,
            requestJSON: requestJSON,
            responseJSON: responseJSON,
            header: copy?.header,
            body: copy?.body,
            actionTitle: actionTitle,
            offerLabel: offerLabel
        )
    }

    // MARK: Load

    /// The traffic mix: 55% subscribers the store knows, 45% it must look up remotely; remote
    /// latency 80% fast, 19% slow, 0.8% past the budget, 0.2% hung.
    static func loadIdentifier(index: Int, run: String) -> String {
        let roll = Int(StableHash.fnv1a64("mix:\(index)") % 100)
        guard roll >= 55 else { return "warm-\(index % 2_000)" }
        let latency = Int(StableHash.fnv1a64("latency:\(index)") % 1_000)
        let suffix: RemoteLatency = latency < 800 ? .fast : latency < 990 ? .slow : latency < 998 ? .beyondBudget : .hung
        return "cold-load-\(run)-\(index)-\(suffix.rawValue)"
    }

    static func warmFacts(count: Int) -> [SubscriptionFact] {
        (0..<count).flatMap { index -> [SubscriptionFact] in
            let id = "warm-\(index)"
            let tenureDays = Int64(StableHash.fnv1a64("tenure:\(index)") % 900)
            let start = LabWorld.epoch - tenureDays * LabWorld.day
            var facts = [SubscriptionFact(
                notificationUUID: StableHash.contentUUID("warm-sub:\(index)"),
                signedDate: start,
                originalTransactionId: id,
                productId: index % 3 == 0 ? LabWorld.proYearly : LabWorld.proMonthly,
                kind: .subscribed(purchaseDate: start, inIntroOffer: tenureDays < 7)
            )]
            if index % 11 == 0 {
                facts.append(SubscriptionFact(
                    notificationUUID: StableHash.contentUUID("warm-retry:\(index)"),
                    signedDate: LabWorld.epoch - LabWorld.day,
                    originalTransactionId: id,
                    productId: nil,
                    kind: .billingRetryStarted
                ))
            }
            return facts
        }
    }

    public static let defaultLoadRequests = 1_200
    public static let defaultLoadRate: Double = 400
    public static let defaultStall: Duration = .milliseconds(300)

    /// Runs the same traffic open-loop and closed-loop, each against a fresh engine, with one
    /// process-wide stall injected a quarter of the way in.
    public static func runLoadComparison(
        world: LabWorld,
        requests: Int = defaultLoadRequests,
        ratePerSecond: Double = defaultLoadRate,
        closedLoopWorkers: Int = 8,
        stall: Duration = defaultStall
    ) async -> LoadComparison {
        let total = min(max(requests, 10), 20_000)
        let stallIndex = total / 4

        func makeRig() -> LabRig {
            let rig = LabRig(world: world, logCapacity: total + 10)
            rig.store.ingest(warmFacts(count: 2_000))
            return rig
        }

        func operation(rig: LabRig, run: String, stallUntil: Locked<Duration?>) -> @Sendable (LoadContext) async -> String {
            let clock = rig.clock
            let configuration = world.configuration
            return { context in
                let id = loadIdentifier(index: context.index, run: run)
                let warmIndex = Int(id.split(separator: "-").last.flatMap { Int($0) } ?? 0)
                let product = id.hasPrefix("warm-") && warmIndex % 3 == 0 ? LabWorld.proYearly : LabWorld.proMonthly
                let request = DecodedRealtimeRequest(
                    originalTransactionId: id,
                    appAppleId: configuration.appAppleId,
                    productId: product,
                    userLocale: LabWorld.locales[context.index % LabWorld.locales.count],
                    requestIdentifier: StableHash.contentUUID("load-\(run)-\(context.index)"),
                    environment: configuration.environment,
                    signedDate: Saturating.add(LabWorld.epoch, Saturating.multiply(Int64(context.index), 50))
                )
                // The stall models a stop-the-world pause *before* the handler runs (GC, a full accept
                // queue). Arrival was stamped at the edge, so the waiting is charged to the budget.
                if context.index == stallIndex {
                    stallUntil.withLock { $0 = clock.now() + stall }
                }
                if let until = stallUntil.withLock({ $0 }), clock.now() < until {
                    try? await clock.sleep(until: until)
                }
                guard let body = try? rig.requestBody(for: request) else { return "encoding-failed" }
                let response = await rig.endpoint.handle(body: body, receivedAt: context.intendedStart)
                return response.decision?.path.label ?? response.rejection?.rawValue ?? "unknown"
            }
        }

        let openRig = makeRig()
        let open = await LoadHarness.runOpenLoop(
            requests: total,
            ratePerSecond: ratePerSecond,
            clock: openRig.clock,
            operation: operation(rig: openRig, run: "open", stallUntil: Locked(nil))
        )
        let closedRig = makeRig()
        let closed = await LoadHarness.runClosedLoop(
            requests: total,
            workers: closedLoopWorkers,
            clock: closedRig.clock,
            operation: operation(rig: closedRig, run: "closed", stallUntil: Locked(nil))
        )
        let readout = simulatedReadout(records: openRig.log.records())
        return LoadComparison(openLoop: open, closedLoop: closed, readout: readout, stall: stall, requests: total)
    }

    /// Joins the open-loop run's decisions to *simulated* subscriber behaviour. The attribution and
    /// statistics are the real code; the behaviour is a seeded model with a built-in treatment effect.
    public static func simulatedReadout(records: [DecisionRecord]) -> ExperimentReadout {
        var facts: [SubscriptionFact] = []
        var latest: Int64 = LabWorld.epoch
        for record in records where !record.isReplay {
            latest = max(latest, record.decidedAt)
            let roll = Double(StableHash.fnv1a64("behaviour:" + record.decisionId) % 10_000) / 10_000
            let redeemRoll = Double(StableHash.fnv1a64("redeem:" + record.decisionId) % 10_000) / 10_000
            if let offer = record.offerId, redeemRoll < 0.30 {
                facts.append(SubscriptionFact(
                    notificationUUID: "sim-redeem-" + record.decisionId,
                    signedDate: Saturating.add(record.decidedAt, 20_000),
                    originalTransactionId: record.originalTransactionId,
                    productId: record.productId,
                    kind: .offerRedeemed(offerId: offer)
                ))
                continue
            }
            let cancelProbability: Double
            switch (record.arm, record.offerId != nil, record.alternateProductId != nil) {
            case (.holdout, _, _): cancelProbability = 0.30
            case (.treatment, true, _): cancelProbability = 0.20
            case (.treatment, _, true): cancelProbability = 0.24
            default: cancelProbability = 0.27
            }
            if roll < cancelProbability {
                facts.append(SubscriptionFact(
                    notificationUUID: "sim-cancel-" + record.decisionId,
                    signedDate: Saturating.add(record.decidedAt, 15_000),
                    originalTransactionId: record.originalTransactionId,
                    productId: record.productId,
                    kind: .autoRenewChanged(enabled: false)
                ))
            }
        }
        let policy = AttributionPolicy()
        let attributions = AttributionEngine(policy: policy).attribute(
            decisions: records,
            facts: facts,
            asOf: Saturating.add(latest, policy.windowMilliseconds + 1)
        )
        return ExperimentReadout.make(from: attributions)
    }
}
