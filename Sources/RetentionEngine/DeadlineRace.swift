import Foundation

/// How a deadline race ended.
public enum RaceOutcome<Value: Sendable>: Sendable {
    case value(Value)
    case failed(any Error)
    case timedOut
    case cancelled
}

/// Runs `operation` and returns as soon as it finishes **or** `deadline` passes — whichever
/// comes first — without ever waiting for the loser.
///
/// The obvious implementation, a `withTaskGroup` that adds the operation and a timer and takes
/// the first result, does **not** bound latency: structured concurrency guarantees the group
/// waits for every child before it returns, and `cancelAll()` only *asks* the slow child to stop.
/// A dependency client that ignores cancellation (a blocking driver, a retry loop, a
/// continuation that is never resumed) keeps the group — and the request — open past the
/// deadline. Here the operation runs in an unstructured task whose result is simply dropped if
/// it loses, so the caller resumes at the deadline no matter what the operation does.
///
/// - Parameters:
///   - deadline: An instant on `clock`. If it has already passed, the race times out at once and
///     the operation is never started.
///   - clock: The clock the deadline is measured on.
///   - operation: The work to race. It is cancelled when it loses, but nothing depends on it noticing.
public func raceDeadline<Value: Sendable>(
    _ deadline: Duration,
    on clock: any DeadlineClock,
    operation: @escaping @Sendable () async throws -> Value
) async -> RaceOutcome<Value> {
    // Deterministic, and cheaper: no work is started that could not possibly be used.
    guard clock.now() < deadline else { return .timedOut }
    let box = RaceBox<Value>()
    return await withTaskCancellationHandler {
        await withCheckedContinuation { (continuation: CheckedContinuation<RaceOutcome<Value>, Never>) in
            box.install(continuation)
            box.track(Task {
                do {
                    box.resolve(.value(try await operation()))
                } catch {
                    box.resolve(.failed(error))
                }
            })
            box.track(Task {
                do {
                    try await clock.sleep(until: deadline)
                    box.resolve(.timedOut)
                } catch {
                    // Cancelled: the operation already won, or the caller went away.
                }
            })
        }
    } onCancel: {
        box.resolve(.cancelled)
    }
}

/// Resolves exactly once, then cancels whatever is still running.
private final class RaceBox<Value: Sendable>: @unchecked Sendable {
    // @unchecked Sendable: all mutable state lives in `state` and is only touched under its lock.
    private struct State {
        var continuation: CheckedContinuation<RaceOutcome<Value>, Never>?
        var outcome: RaceOutcome<Value>?
        var tasks: [Task<Void, Never>] = []
    }

    private let state = Locked(State())

    func install(_ continuation: CheckedContinuation<RaceOutcome<Value>, Never>) {
        let early: RaceOutcome<Value>? = state.withLock { state in
            if let outcome = state.outcome { return outcome }
            state.continuation = continuation
            return nil
        }
        // Cancelled before the continuation existed: resume right away with the stored outcome.
        if let early { continuation.resume(returning: early) }
    }

    func track(_ task: Task<Void, Never>) {
        let alreadyResolved = state.withLock { state -> Bool in
            if state.outcome != nil { return true }
            state.tasks.append(task)
            return false
        }
        if alreadyResolved { task.cancel() }
    }

    func resolve(_ outcome: RaceOutcome<Value>) {
        let settled: (CheckedContinuation<RaceOutcome<Value>, Never>?, [Task<Void, Never>])? =
            state.withLock { state in
                guard state.outcome == nil else { return nil }
                state.outcome = outcome
                let continuation = state.continuation
                let tasks = state.tasks
                state.continuation = nil
                state.tasks = []
                return (continuation, tasks)
            }
        guard let (continuation, tasks) = settled else { return }
        continuation?.resume(returning: outcome)
        for task in tasks { task.cancel() }
    }
}
