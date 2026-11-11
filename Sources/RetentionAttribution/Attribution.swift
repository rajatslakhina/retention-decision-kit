import Foundation
import RetentionEngine

/// How outcomes are joined to decisions.
public struct AttributionPolicy: Codable, Sendable, Hashable {
    /// How long after a decision its outcome is still open. Cancellation happens seconds after the
    /// message, but notifications can be delayed or retried, so the default is generous.
    public let windowMilliseconds: Int64
    /// Tolerance for a fact stamped slightly before the first decision it belongs to. Requests and
    /// notifications are both signed by Apple, so this only absorbs small skew.
    public let clockSkewToleranceMilliseconds: Int64

    public init(windowMilliseconds: Int64 = 86_400_000, clockSkewToleranceMilliseconds: Int64 = 5_000) {
        let window = max(1, windowMilliseconds)
        self.windowMilliseconds = window
        self.clockSkewToleranceMilliseconds = min(max(0, clockSkewToleranceMilliseconds), window)
    }

    private enum CodingKeys: String, CodingKey { case windowMilliseconds, clockSkewToleranceMilliseconds }

    /// Decoding goes through the clamping initializer: a configuration file cannot set what code cannot.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            windowMilliseconds: try container.decode(Int64.self, forKey: .windowMilliseconds),
            clockSkewToleranceMilliseconds: try container.decode(Int64.self, forKey: .clockSkewToleranceMilliseconds)
        )
    }
}

/// What happened after one decision.
///
/// Note what is *not* here: "saved by the message". Apple calls the endpoint when a subscriber
/// *views* subscription details and shows the message only if they then tap Cancel, so most
/// requests come from people who were never going to cancel. A request is an eligibility event,
/// not an exposure; only the arm comparison says what the messages did.
public enum AttributedOutcome: String, Codable, Sendable, Hashable, CaseIterable {
    /// Redeemed the promotional offer the decision served.
    case redeemedOffer
    /// Switched to the alternate product the decision suggested.
    case switchedPlan
    /// Still renewing when the window closed.
    case retained
    /// Turned auto-renew off (or expired) and had not turned it back on when the window closed.
    case cancelled
    /// The window has not closed yet.
    case pending
    /// Another decision for the same subscriber happened at the same instant; this one never had a window.
    case superseded
}

public struct Attribution: Sendable, Hashable {
    public let record: DecisionRecord
    public let outcome: AttributedOutcome
    /// The `notificationUUID` of the fact that decided the outcome, if one did.
    public let evidence: String?
    public let windowStart: Int64
    public let windowEnd: Int64
}

/// Joins decision records to subscription facts.
///
/// The join is a pure function of the *sets* of decisions and facts: duplicates (retried
/// notifications, a fact reported by both the server and the app) and arrival order cannot
/// change the result. Each decision owns the window from its own time until the next decision
/// for the same subscriber or the policy window — last touch wins.
public struct AttributionEngine: Sendable {
    public let policy: AttributionPolicy

    public init(policy: AttributionPolicy = AttributionPolicy()) {
        self.policy = policy
    }

    public func attribute(decisions: [DecisionRecord], facts: [SubscriptionFact], asOf now: Int64) -> [Attribution] {
        var uniqueDecisions: [String: DecisionRecord] = [:]
        for record in decisions where !record.isReplay {
            if let existing = uniqueDecisions[record.decisionId], existing.decidedAt <= record.decidedAt { continue }
            uniqueDecisions[record.decisionId] = record
        }
        var uniqueFacts: [String: SubscriptionFact] = [:]
        for fact in facts {
            if let existing = uniqueFacts[fact.notificationUUID], existing.clock <= fact.clock { continue }
            uniqueFacts[fact.notificationUUID] = fact
        }
        let factsBySubscriber = Dictionary(grouping: uniqueFacts.values, by: \.originalTransactionId)
            .mapValues { $0.sorted { $0.clock < $1.clock } }
        let decisionsBySubscriber = Dictionary(grouping: uniqueDecisions.values, by: \.originalTransactionId)

        var result: [Attribution] = []
        for subscriber in decisionsBySubscriber.keys.sorted() {
            let ordered = (decisionsBySubscriber[subscriber] ?? []).sorted {
                ($0.decidedAt, $0.decisionId) < ($1.decidedAt, $1.decisionId)
            }
            let subscriberFacts = factsBySubscriber[subscriber] ?? []
            for (index, record) in ordered.enumerated() {
                let start = index == 0
                    ? Saturating.subtract(record.decidedAt, policy.clockSkewToleranceMilliseconds)
                    : record.decidedAt
                let natural = Saturating.add(record.decidedAt, policy.windowMilliseconds)
                let next = ordered.indices.contains(index + 1) ? ordered[index + 1].decidedAt : Int64.max
                let end = min(natural, next)
                // Another decision at the very same instant replaces this one before it can have an outcome.
                guard next > record.decidedAt, end > start else {
                    result.append(Attribution(record: record, outcome: .superseded, evidence: nil, windowStart: start, windowEnd: end))
                    continue
                }
                let inWindow = subscriberFacts.filter { $0.signedDate >= start && $0.signedDate < end }
                let (outcome, evidence) = classify(record, facts: inWindow, windowClosed: now >= end)
                result.append(Attribution(record: record, outcome: outcome, evidence: evidence, windowStart: start, windowEnd: end))
            }
        }
        return result
    }

    private func classify(_ record: DecisionRecord, facts: [SubscriptionFact], windowClosed: Bool) -> (AttributedOutcome, String?) {
        if let offer = record.offerId, let fact = facts.first(where: {
            if case .offerRedeemed(let id) = $0.kind { return id == offer }
            return false
        }) {
            return (.redeemedOffer, fact.notificationUUID)
        }
        if let alternate = record.alternateProductId, let fact = facts.first(where: {
            if case .renewalPreferenceChanged(let product) = $0.kind { return product == alternate }
            return false
        }) {
            return (.switchedPlan, fact.notificationUUID)
        }
        guard windowClosed else { return (.pending, nil) }
        let lastStatus = facts.last { fact in
            switch fact.kind {
            case .autoRenewChanged, .expired: return true
            default: return false
            }
        }
        switch lastStatus?.kind {
        case .autoRenewChanged(enabled: false)?, .expired?:
            return (.cancelled, lastStatus?.notificationUUID)
        default:
            return (.retained, lastStatus?.notificationUUID)
        }
    }
}
