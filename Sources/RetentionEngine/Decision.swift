import Foundation

/// Why the engine answered with the product's safe fallback instead of a personalized message.
public enum FallbackReason: String, Codable, Sendable, Hashable, CaseIterable {
    /// Not in L1, and there is no remote source or it does not know the subscriber.
    case featuresMissing
    /// The remote lookup did not finish inside its slice of the budget.
    case featuresTimedOut
    /// The remote lookup threw.
    case featuresFailed
    /// The breaker is open: the remote source has been failing, so it was not called.
    case breakerOpen
    /// The request had already used up the time the lookup needed.
    case budgetExhausted
    /// Every ranked candidate was ineligible or could not be completed in time.
    case noEligibleCandidate
}

/// The route a request took through the engine.
public enum DecisionPath: Codable, Sendable, Hashable {
    case personalized
    case holdoutControl
    case fallback(FallbackReason)
    /// No approved message exists for this product and locale: answer with an error so Apple
    /// shows the message configured in App Store Connect or its default message.
    case deferToApple
    /// A duplicate of a request already decided (or being decided): same response, byte for byte.
    case replayed(originalDecisionId: String)

    public var label: String {
        switch self {
        case .personalized: return "personalized"
        case .holdoutControl: return "holdout-control"
        case .fallback(let reason): return "fallback:\(reason.rawValue)"
        case .deferToApple: return "defer-to-apple"
        case .replayed: return "replayed"
        }
    }
}

/// Observations made while deciding, for logs and the demo's timeline.
public enum DecisionNote: String, Codable, Sendable, Hashable {
    case l1Hit, l1Miss
    case l2Hit, l2Miss, l2TimedOut, l2Failed
    case l2SkippedBreakerOpen, l2SkippedNoBudget, l2Unavailable
    case localeFallback
    case offerIneligible
    case offerSignerUnavailable
    case offerSigningTimedOut, offerSigningFailed, offerSigningSkippedNoBudget
    case switchPlanSkippedSameProduct
}

/// Where the time went. Every value is measured on the engine's ``DeadlineClock``.
public struct StageTimings: Sendable, Hashable {
    public var featureLookup: Duration?
    public var signing: Duration?
    /// From `receivedAt` to the moment the decision was ready.
    public var total: Duration

    public init(featureLookup: Duration? = nil, signing: Duration? = nil, total: Duration = .zero) {
        self.featureLookup = featureLookup
        self.signing = signing
        self.total = total
    }
}

/// One decision.
public struct Decision: Sendable, Hashable {
    /// Deterministic per `requestIdentifier`, so a replay and its original share an identifier and
    /// downstream consumers can deduplicate.
    public let decisionId: String
    public let request: DecodedRealtimeRequest
    public let arm: Arm
    public let path: DecisionPath
    /// `nil` only for ``DecisionPath/deferToApple``.
    public let response: RealtimeResponse?
    public let entry: CatalogEntry?
    public let resolvedLocale: String?
    public let segment: Segment?
    public let notes: [DecisionNote]
    public let timings: StageTimings
    public let catalogVersion: String

    public init(
        decisionId: String,
        request: DecodedRealtimeRequest,
        arm: Arm,
        path: DecisionPath,
        response: RealtimeResponse?,
        entry: CatalogEntry?,
        resolvedLocale: String?,
        segment: Segment?,
        notes: [DecisionNote],
        timings: StageTimings,
        catalogVersion: String
    ) {
        self.decisionId = decisionId
        self.request = request
        self.arm = arm
        self.path = path
        self.response = response
        self.entry = entry
        self.resolvedLocale = resolvedLocale
        self.segment = segment
        self.notes = notes
        self.timings = timings
        self.catalogVersion = catalogVersion
    }

    /// Stable for every duplicate of one request; different for two different requests that share
    /// a `requestIdentifier` (the same distinction the replay key makes), so attribution never
    /// merges them.
    public static func identifier(for request: DecodedRealtimeRequest) -> String {
        let identity = [
            request.requestIdentifier, request.originalTransactionId, String(request.appAppleId),
            request.productId, request.userLocale, request.environment.rawValue,
        ]
        return "dec-" + StableHash.contentUUID("decision:" + identity.joined(separator: "\u{1F}"))
    }

    func replay(timings: StageTimings) -> Decision {
        Decision(
            decisionId: decisionId,
            request: request,
            arm: arm,
            path: .replayed(originalDecisionId: decisionId),
            response: response,
            entry: entry,
            resolvedLocale: resolvedLocale,
            segment: segment,
            notes: notes,
            timings: timings,
            catalogVersion: catalogVersion
        )
    }

    /// The flat, durable form shipped to the decision log and joined against outcomes later.
    public var record: DecisionRecord {
        var offerId: String?
        var alternateProductId: String?
        switch entry?.kind {
        case .promotionalOffer(let offer)?:
            if case .promotionalOffer = response { offerId = offer }
        case .switchPlan(let product)?:
            alternateProductId = product
        case .text?, nil:
            break
        }
        return DecisionRecord(
            decisionId: decisionId,
            requestIdentifier: request.requestIdentifier,
            originalTransactionId: request.originalTransactionId,
            productId: request.productId,
            locale: resolvedLocale ?? request.userLocale,
            arm: arm,
            pathLabel: path.label,
            isReplay: { if case .replayed = path { return true } else { return false } }(),
            messageIdentifier: response?.messageIdentifier,
            variantId: entry?.variantId,
            offerId: offerId,
            alternateProductId: alternateProductId,
            decidedAt: request.signedDate,
            totalMicroseconds: Saturating.microseconds(timings.total),
            catalogVersion: catalogVersion
        )
    }
}

/// The durable record of a decision. `decidedAt` is Apple's `signedDate` for the request — the
/// same clock App Store Server Notifications are stamped with, which is what makes joining
/// outcomes to decisions reliable.
public struct DecisionRecord: Codable, Sendable, Hashable {
    public let decisionId: String
    public let requestIdentifier: String
    public let originalTransactionId: String
    public let productId: String
    public let locale: String
    public let arm: Arm
    public let pathLabel: String
    public let isReplay: Bool
    public let messageIdentifier: String?
    public let variantId: String?
    public let offerId: String?
    public let alternateProductId: String?
    public let decidedAt: Int64
    public let totalMicroseconds: Int64
    public let catalogVersion: String

    public init(
        decisionId: String,
        requestIdentifier: String,
        originalTransactionId: String,
        productId: String,
        locale: String,
        arm: Arm,
        pathLabel: String,
        isReplay: Bool,
        messageIdentifier: String?,
        variantId: String?,
        offerId: String?,
        alternateProductId: String?,
        decidedAt: Int64,
        totalMicroseconds: Int64,
        catalogVersion: String
    ) {
        self.decisionId = decisionId
        self.requestIdentifier = requestIdentifier
        self.originalTransactionId = originalTransactionId
        self.productId = productId
        self.locale = locale
        self.arm = arm
        self.pathLabel = pathLabel
        self.isReplay = isReplay
        self.messageIdentifier = messageIdentifier
        self.variantId = variantId
        self.offerId = offerId
        self.alternateProductId = alternateProductId
        self.decidedAt = decidedAt
        self.totalMicroseconds = totalMicroseconds
        self.catalogVersion = catalogVersion
    }
}

/// Receives decision records. Implementations must not block: hand off to a queue or a
/// bounded buffer and return. A slow sink would otherwise spend the response budget.
public protocol DecisionSink: Sendable {
    func record(_ record: DecisionRecord)
}

/// A bounded in-memory decision log. Production ships records to a durable log instead.
public final class RingBufferDecisionLog: DecisionSink, Sendable {
    private struct State {
        var buffer: [DecisionRecord?]
        var next = 0
        var total = 0
    }

    public let capacity: Int
    private let state: Locked<State>

    /// - Parameter capacity: Clamped to `1...1_000_000`.
    public init(capacity: Int) {
        let clamped = min(max(capacity, 1), 1_000_000)
        self.capacity = clamped
        state = Locked(State(buffer: Array(repeating: nil, count: clamped)))
    }

    public func record(_ record: DecisionRecord) {
        state.withLock { state in
            state.buffer[state.next] = record
            state.next = (state.next + 1) % capacity
            state.total &+= 1
        }
    }

    /// Everything still held, oldest first.
    public func records() -> [DecisionRecord] {
        state.withLock { state in
            let tail = state.buffer[state.next...].compactMap { $0 }
            let head = state.buffer[..<state.next].compactMap { $0 }
            return tail + head
        }
    }

    /// Records ever written, including those evicted.
    public var totalRecorded: Int { state.withLock { $0.total } }
}
