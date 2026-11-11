import Foundation

/// Monotonic time, injected everywhere a deadline is enforced.
///
/// The engine never reads wall-clock time for decisions. Deadlines run on this clock;
/// business time (cool-downs, tenure) comes from the request's Apple-signed `signedDate`,
/// so the same request always produces the same decision.
public protocol DeadlineClock: Sendable {
    /// Time elapsed since an arbitrary, fixed origin.
    func now() -> Duration
    /// Suspends until `now() >= deadline`; throws `CancellationError` if the task is cancelled first.
    func sleep(until deadline: Duration) async throws
}

/// `ContinuousClock`, measured from one process-wide origin.
///
/// Every instance agrees: an instant stamped by one `SystemDeadlineClock()` means the same thing to
/// any other. (An origin per instance would make an endpoint and an engine created at different
/// times disagree about every deadline — silently, since each would still answer `200`.)
public struct SystemDeadlineClock: DeadlineClock {
    private static let origin = ContinuousClock.now
    /// Longest single `Task.sleep`; longer waits loop, so no conversion inside the runtime can overflow.
    private static let maximumSleep: Duration = .seconds(3_600)

    public init() {}

    public func now() -> Duration {
        Self.origin.duration(to: ContinuousClock.now)
    }

    public func sleep(until deadline: Duration) async throws {
        while true {
            let remaining = deadline - now()
            guard remaining > .zero else {
                try Task.checkCancellation()
                return
            }
            try await Task.sleep(for: min(remaining, Self.maximumSleep))
        }
    }
}

/// A clock that only moves when told to. Deadline behaviour becomes deterministic:
/// a test parks the work, waits for the engine's timer to register, and advances time
/// past the deadline — no real sleeping, no flaky margins.
public final class ManualClock: DeadlineClock, @unchecked Sendable {
    // @unchecked Sendable: `state` is a `Locked`, and continuations are resumed outside the lock.
    private enum Phase {
        case pending
        case cancelledBeforeRegistration
        case registered(deadline: Duration, continuation: CheckedContinuation<Void, any Error>)
    }

    private struct State {
        var now: Duration
        var nextID: UInt64 = 0
        var phases: [UInt64: Phase] = [:]
    }

    private let state: Locked<State>

    public init(now: Duration = .zero) {
        state = Locked(State(now: now))
    }

    public func now() -> Duration {
        state.withLock { $0.now }
    }

    /// The number of tasks currently suspended in `sleep(until:)`.
    public var sleeperCount: Int {
        state.withLock { state in
            state.phases.values.reduce(into: 0) { count, phase in
                if case .registered = phase { count += 1 }
            }
        }
    }

    public func sleep(until deadline: Duration) async throws {
        let id: UInt64 = state.withLock { state in
            state.nextID &+= 1
            state.phases[state.nextID] = .pending
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enum Action { case resume, cancel, wait }
                let action: Action = state.withLock { state in
                    guard let phase = state.phases[id] else { return .resume }
                    if case .cancelledBeforeRegistration = phase {
                        state.phases[id] = nil
                        return .cancel
                    }
                    if deadline <= state.now {
                        state.phases[id] = nil
                        return .resume
                    }
                    state.phases[id] = .registered(deadline: deadline, continuation: continuation)
                    return .wait
                }
                switch action {
                case .resume: continuation.resume()
                case .cancel: continuation.resume(throwing: CancellationError())
                case .wait: break
                }
            }
        } onCancel: {
            let continuation: CheckedContinuation<Void, any Error>? = state.withLock { state in
                switch state.phases[id] {
                case .registered(_, let continuation):
                    state.phases[id] = nil
                    return continuation
                case .pending:
                    state.phases[id] = .cancelledBeforeRegistration
                    return nil
                case .cancelledBeforeRegistration, .none:
                    return nil
                }
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// The furthest a manual clock can be advanced; keeps every sum far from `Duration`'s limits.
    public static let maximumTime: Duration = .seconds(Int64.max / 4)

    /// Moves time forward (saturating at ``maximumTime``) and resumes every sleeper whose deadline has passed.
    public func advance(by duration: Duration) {
        guard duration > .zero else { return }
        let due: [CheckedContinuation<Void, any Error>] = state.withLock { state in
            let step = min(duration, Self.maximumTime)
            state.now = min(state.now + step, Self.maximumTime)
            var ready: [CheckedContinuation<Void, any Error>] = []
            for (id, phase) in state.phases {
                if case .registered(let deadline, let continuation) = phase, deadline <= state.now {
                    state.phases[id] = nil
                    ready.append(continuation)
                }
            }
            return ready
        }
        for continuation in due { continuation.resume() }
    }

    /// Advances time to `instant` if it is in the future.
    public func advance(to instant: Duration) {
        advance(by: instant - now())
    }

    /// Waits (by yielding, never by sleeping) until at least `count` tasks are suspended in `sleep`.
    /// Returns `false` if that does not happen within `maxYields` scheduler turns.
    @discardableResult
    public func waitForSleepers(atLeast count: Int, maxYields: Int = 200_000) async -> Bool {
        for _ in 0..<max(maxYields, 1) {
            if sleeperCount >= count { return true }
            await Task.yield()
        }
        return sleeperCount >= count
    }
}
