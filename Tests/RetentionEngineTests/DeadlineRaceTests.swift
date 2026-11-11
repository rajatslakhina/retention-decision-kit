import XCTest
@testable import RetentionEngine

/// The broken implementation the engine deliberately does not use: a task-group race.
/// Correct-looking, and unable to return before a non-cooperative child finishes.
func taskGroupRace<Value: Sendable>(
    _ deadline: Duration,
    on clock: any DeadlineClock,
    operation: @escaping @Sendable () async throws -> Value
) async -> RaceOutcome<Value> {
    await withTaskGroup(of: RaceOutcome<Value>.self) { group in
        group.addTask {
            do { return .value(try await operation()) } catch { return .failed(error) }
        }
        group.addTask {
            do {
                try await clock.sleep(until: deadline)
                return .timedOut
            } catch {
                return .cancelled
            }
        }
        let first = await group.next() ?? .timedOut
        group.cancelAll()
        return first  // ...but the group still waits for every child before this returns.
    }
}

final class DeadlineRaceTests: XCTestCase {
    func testManualClockResumesSleepersOnlyWhenDue() async {
        let clock = ManualClock()
        let woke = Locked(false)
        let sleeper = Task {
            try? await clock.sleep(until: .milliseconds(100))
            woke.withLock { $0 = true }
        }
        let registered = await clock.waitForSleepers(atLeast: 1)
        XCTAssertTrue(registered)
        clock.advance(by: .milliseconds(99))
        for _ in 0..<1_000 { await Task.yield() }
        XCTAssertFalse(woke.withLock { $0 })
        clock.advance(by: .milliseconds(1))
        let finished: Void? = await completes(sleeper, within: 10)
        XCTAssertNotNil(finished, "the sleeper never woke")
        XCTAssertTrue(woke.withLock { $0 })
        XCTAssertEqual(clock.sleeperCount, 0)
    }

    func testManualClockCancellationRemovesSleeper() async {
        let clock = ManualClock()
        let task = Task { () -> Bool in
            do {
                try await clock.sleep(until: .seconds(10))
                return false
            } catch {
                return error is CancellationError
            }
        }
        await clock.waitForSleepers(atLeast: 1)
        task.cancel()
        let cancelled = await completes(task, within: 10)
        XCTAssertEqual(cancelled, true)
        XCTAssertEqual(clock.sleeperCount, 0)
    }

    func testPastDeadlineReturnsImmediately() async throws {
        let clock = ManualClock(now: .seconds(5))
        try await clock.sleep(until: .seconds(1))
        XCTAssertEqual(clock.sleeperCount, 0)
    }

    func testValueBeforeDeadlineWins() async {
        let clock = ManualClock()
        let outcome = await raceDeadline(.seconds(1), on: clock) { 42 }
        guard case .value(42) = outcome else { return XCTFail("expected value, got \(outcome)") }
        // The losing timer was cancelled, not left registered.
        let drained = await waitUntil { clock.sleeperCount == 0 }
        XCTAssertTrue(drained)
    }

    func testErrorsAreReported() async {
        struct Boom: Error {}
        let outcome = await raceDeadline(.seconds(1), on: ManualClock()) { () throws -> Int in throw Boom() }
        guard case .failed(let error) = outcome else { return XCTFail("expected failure") }
        XCTAssertTrue(error is Boom)
    }

    /// The property the engine's latency bound rests on: a hung, non-cooperative operation does
    /// not keep the caller past the deadline.
    func testNonCooperativeOperationLosesAtDeadline() async throws {
        let clock = ManualClock()
        let gate = GatedSource(result: nil)
        let race = Task { await raceDeadline(.milliseconds(300), on: clock) { try await gate.features(for: "x") } }
        await clock.waitForSleepers(atLeast: 1)
        clock.advance(by: .milliseconds(300))
        guard let outcome = await completes(race) else { return XCTFail("the race did not return at its deadline") }
        guard case .timedOut = outcome else { return XCTFail("expected timeout, got \(outcome)") }
        XCTAssertEqual(clock.now(), .milliseconds(300))
        gate.release()
    }

    /// The same scenario against the task-group race: it does NOT return at the deadline. This is
    /// what proves the test above is not vacuous — the obvious implementation fails it.
    func testTaskGroupRaceIsHeldOpenByNonCooperativeChild() async {
        let clock = ManualClock()
        let gate = GatedSource(result: nil)
        let finished = Locked(false)
        let race = Task { () -> RaceOutcome<SubscriberFeatures?> in
            let outcome = await taskGroupRace(.milliseconds(300), on: clock) { try await gate.features(for: "x") }
            finished.withLock { $0 = true }
            return outcome
        }
        await clock.waitForSleepers(atLeast: 1)
        clock.advance(by: .milliseconds(300))
        // Give it every chance to return; it cannot, because the hung child is still running.
        for _ in 0..<5_000 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(finished.withLock { $0 }, "a task-group race must not be able to bound latency here")
        gate.release()
        _ = await race.value
        XCTAssertTrue(finished.withLock { $0 })
    }

    func testCallerCancellationResolvesRace() async {
        let clock = ManualClock()
        let gate = GatedSource(result: nil)
        let race = Task { await raceDeadline(.seconds(60), on: clock) { try await gate.features(for: "x") } }
        await clock.waitForSleepers(atLeast: 1)
        race.cancel()
        let finished = await completes(race, within: 10)
        guard case .cancelled? = finished else { return XCTFail("expected cancelled, got \(String(describing: finished))") }
        gate.release()
    }

    func testDeadlineAlreadyPassedTimesOutWithoutWaiting() async {
        let clock = ManualClock(now: .seconds(10))
        let gate = GatedSource(result: nil)
        let outcome = await raceDeadline(.seconds(1), on: clock) { try await gate.features(for: "x") }
        guard case .timedOut = outcome else { return XCTFail("expected timeout, got \(outcome)") }
        XCTAssertEqual(gate.calls, 0, "work that cannot be used is never started")
        let instant = await raceDeadline(.seconds(1), on: clock) { 1 }
        guard case .timedOut = instant else { return XCTFail("even an instant operation loses to a passed deadline, deterministically") }
        gate.release()
    }
}

/// Polls `condition` by yielding (never sleeping on the test clock).
func waitUntil(maxYields: Int = 100_000, _ condition: () -> Bool) async -> Bool {
    for _ in 0..<maxYields {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}
