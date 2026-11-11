import Foundation
import RetentionEngine

/// One arm's results, per subscriber (the randomization unit), not per request.
public struct ArmReadout: Sendable, Hashable {
    public let arm: Arm
    /// Subscribers whose outcome is settled: every window has closed, or one already ended in a
    /// cancellation (a subscriber counts as cancelled if any of their windows did).
    public let resolvedSubscribers: Int
    public let pendingSubscribers: Int
    public let cancelled: Int
    public let redeemedOffer: Int
    public let switchedPlan: Int

    public var cancellationRate: Double? {
        resolvedSubscribers > 0 ? Double(cancelled) / Double(resolvedSubscribers) : nil
    }

    public var cancellationInterval: ClosedRange<Double>? {
        Wilson.interval(successes: cancelled, trials: resolvedSubscribers)
    }
}

/// A difference of two proportions with its 95% interval.
public struct ProportionDifference: Sendable, Hashable {
    public let estimate: Double
    public let lower: Double
    public let upper: Double

    /// The interval excludes zero.
    public var isSignificant: Bool { lower > 0 || upper < 0 }
}

/// Treatment versus holdout.
///
/// The headline is *cancellations prevented*: holdout cancellation rate minus treatment
/// cancellation rate. Absolute rates are diluted by subscribers who only viewed the page (see
/// ``AttributedOutcome``), but both arms are diluted the same way, so the difference is honest.
public struct ExperimentReadout: Sendable, Hashable {
    public let treatment: ArmReadout
    public let holdout: ArmReadout
    public let preventedCancellations: ProportionDifference?

    public static func make(from attributions: [Attribution]) -> ExperimentReadout {
        // Per subscriber: cancelled if any window ended cancelled; pending if any window is open.
        struct Tally {
            var cancelled = false
            var pending = false
            var redeemed = false
            var switched = false
        }
        var tallies: [Arm: [String: Tally]] = [:]
        for attribution in attributions where attribution.outcome != .superseded {
            let arm = attribution.record.arm
            var tally = tallies[arm]?[attribution.record.originalTransactionId] ?? Tally()
            switch attribution.outcome {
            case .cancelled: tally.cancelled = true
            case .pending: tally.pending = true
            case .redeemedOffer: tally.redeemed = true
            case .switchedPlan: tally.switched = true
            case .retained, .superseded: break
            }
            tallies[arm, default: [:]][attribution.record.originalTransactionId] = tally
        }
        func readout(_ arm: Arm) -> ArmReadout {
            let values = Array((tallies[arm] ?? [:]).values)
            let resolved = values.filter { !$0.pending || $0.cancelled }
            return ArmReadout(
                arm: arm,
                resolvedSubscribers: resolved.count,
                pendingSubscribers: values.count - resolved.count,
                cancelled: resolved.filter(\.cancelled).count,
                redeemedOffer: values.filter(\.redeemed).count,
                switchedPlan: values.filter(\.switched).count
            )
        }
        let treatment = readout(.treatment)
        let holdout = readout(.holdout)
        let difference = Wilson.differenceInterval(
            successes1: holdout.cancelled, trials1: holdout.resolvedSubscribers,
            successes2: treatment.cancelled, trials2: treatment.resolvedSubscribers
        ).map { ProportionDifference(estimate: $0.estimate, lower: $0.interval.lowerBound, upper: $0.interval.upperBound) }
        return ExperimentReadout(treatment: treatment, holdout: holdout, preventedCancellations: difference)
    }
}
