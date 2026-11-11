import XCTest
@testable import RetentionEngine

final class LatencyTests: XCTestCase {
    func exactQuantile(_ sorted: [Int64], _ q: Double) -> Int64 {
        let rank = max(1, Int((q * Double(sorted.count)).rounded(.up)))
        return sorted[min(rank, sorted.count) - 1]
    }

    /// Compared against an independent exact computation: never below, at most 1% above.
    func testQuantilesMatchExactWithinOnePercentAndNeverUnderReport() throws {
        var generator = SplitMix64(seed: 99)
        var histogram = LatencyHistogram()
        var samples: [Int64] = []
        for _ in 0..<20_000 {
            let roll = Double(generator.next() % 1_000_000) / 1_000_000
            // A long-tailed mix: mostly fast, some slow, a few very slow.
            let micros: Int64 = roll < 0.9 ? Int64(generator.next() % 5_000) : roll < 0.99 ? 5_000 + Int64(generator.next() % 200_000) : 200_000 + Int64(generator.next() % 2_000_000)
            histogram.record(microseconds: micros)
            samples.append(micros)
        }
        let sorted = samples.sorted()
        for q in [0.0, 0.5, 0.9, 0.95, 0.99, 0.999, 1.0] {
            let exact = exactQuantile(sorted, q)
            let reported = Saturating.microseconds(try XCTUnwrap(histogram.quantile(q)))
            XCTAssertGreaterThanOrEqual(reported, exact, "q=\(q)")
            XCTAssertLessThanOrEqual(Double(reported), Double(exact) * 1.01 + 1, "q=\(q)")
        }
        XCTAssertEqual(histogram.count, 20_000)
        XCTAssertEqual(histogram.maximumMicroseconds, sorted.last)
    }

    func testBucketBoundsContainTheirValues() {
        var generator = SplitMix64(seed: 5)
        for _ in 0..<5_000 {
            let value = Int64(generator.next() % 99_999_999_999)
            let index = LatencyHistogram.bucketIndex(forMicroseconds: value)
            XCTAssertTrue((0..<LatencyHistogram.bucketCount).contains(index))
            let upper = LatencyHistogram.upperBoundMicroseconds(ofBucket: index)
            XCTAssertGreaterThanOrEqual(upper, value)
            let lower = index == 0 ? 0 : LatencyHistogram.upperBoundMicroseconds(ofBucket: index - 1) + 1
            XCTAssertLessThanOrEqual(lower, value)
        }
    }

    func testEdgeCases() {
        var histogram = LatencyHistogram()
        XCTAssertNil(histogram.quantile(0.5))
        XCTAssertNil(histogram.mean)
        histogram.record(.seconds(-3))
        histogram.record(microseconds: .max)
        XCTAssertEqual(histogram.minimumMicroseconds, 0)
        XCTAssertEqual(histogram.maximumMicroseconds, LatencyHistogram.maximumTrackableMicroseconds)
        XCTAssertNil(histogram.quantile(.nan))
        XCTAssertNil(histogram.quantile(-0.1))
        XCTAssertNil(histogram.quantile(1.1))
        XCTAssertEqual(histogram.quantile(1), .microseconds(LatencyHistogram.maximumTrackableMicroseconds))
    }

    func testMergeEqualsRecordingEverything() {
        var a = LatencyHistogram()
        var b = LatencyHistogram()
        var all = LatencyHistogram()
        for value in stride(from: Int64(0), to: 300_000, by: 997) {
            if value % 2 == 0 { a.record(microseconds: value) } else { b.record(microseconds: value) }
            all.record(microseconds: value)
        }
        a.merge(b)
        XCTAssertEqual(a, all)
    }

    func testIntendedOffsetsAndClamps() {
        XCTAssertEqual(LoadHarness.intendedOffset(index: 400, ratePerSecond: 400), .seconds(1))
        XCTAssertEqual(LoadHarness.intendedOffset(index: -5, ratePerSecond: 400), .zero)
        XCTAssertEqual(LoadHarness.intendedOffset(index: 3, ratePerSecond: .nan), .seconds(3))
        XCTAssertEqual(LoadHarness.intendedOffset(index: 3, ratePerSecond: -1), .seconds(3))
    }

    /// The open-loop harness measures from the *intended* start. Here the issuer itself is frozen
    /// for 300 ms (a paused load generator): the requests due meanwhile go out late, and only the
    /// intended-start measurement shows it.
    func testOpenLoopChargesAnIssuerStallToTheRequestsItDelayed() async throws {
        let clock = ManualClock()
        let served = Locked(0)
        let run = Task {
            await LoadHarness.runOpenLoop(requests: 40, ratePerSecond: 1_000, clock: clock) { _ in
                served.withLock { $0 += 1 }
                return "ok"
            }
        }
        for _ in 0..<20 {
            await clock.waitForSleepers(atLeast: 1)
            clock.advance(by: .milliseconds(1))
        }
        await clock.waitForSleepers(atLeast: 1)
        // Let the 21 requests already sent finish before time jumps, so none of them spans the stall.
        var spins = 0
        while served.withLock({ $0 }) < 21, spins < 200_000 {
            spins += 1
            await Task.yield()
        }
        clock.advance(by: .milliseconds(300))  // requests 21…39 were due at 21…39 ms; all go out at 320 ms
        let finished = await completes(run, within: 10)
        let report = try XCTUnwrap(finished)
        XCTAssertEqual(report.requests, 40)
        // 19 of the 40 went out late, so the 75th percentile is one of them.
        let fromIntended = try XCTUnwrap(report.fromIntendedStart.quantile(0.75))
        let fromActual = try XCTUnwrap(report.fromActualStart.quantile(0.75))
        XCTAssertGreaterThanOrEqual(fromIntended, .milliseconds(280), "requests due at 21–39 ms left at 320 ms")
        XCTAssertLessThan(fromActual, .milliseconds(2), "timed from their actual start, the same requests look instant")
    }

    /// "Later than Apple" means more than 700 ms from the intended start: exactly 700 ms is in time.
    func testReportCountsAnswersLaterThanApple() {
        let samples = [
            LoadSample(index: 0, intendedStart: .zero, actualStart: .zero, end: .milliseconds(700), label: "ok"),
            LoadSample(index: 1, intendedStart: .zero, actualStart: .milliseconds(650), end: .milliseconds(701), label: "ok"),
            LoadSample(index: 2, intendedStart: .seconds(1), actualStart: .seconds(1), end: .seconds(1) + .milliseconds(5), label: "ok"),
        ]
        let report = LoadHarness.report(.openLoop, samples: samples, wallTime: .seconds(2))
        XCTAssertEqual(report.lateAgainstApple, 1)
        XCTAssertEqual(report.requests, 3)
    }

    /// Coordinated omission, demonstrated on a real clock: the same 300 ms stall is invisible to a
    /// closed-loop p99 and dominates the open-loop p95. Effect sizes are large so CI noise cannot flip it.
    func testOpenLoopSeesTheStallClosedLoopHides() async {
        let clock = SystemDeadlineClock()
        func operation(stallAt: Int) -> @Sendable (LoadContext) async -> String {
            let stallUntil = Locked<Duration?>(nil)
            return { context in
                if context.index == stallAt { stallUntil.withLock { $0 = clock.now() + .milliseconds(300) } }
                if let until = stallUntil.withLock({ $0 }), clock.now() < until { try? await clock.sleep(until: until) }
                return "ok"
            }
        }
        let open = await LoadHarness.runOpenLoop(requests: 600, ratePerSecond: 300, clock: clock, operation: operation(stallAt: 150))
        let closed = await LoadHarness.runClosedLoop(requests: 600, workers: 2, clock: clock, operation: operation(stallAt: 150))
        XCTAssertEqual(open.requests, 600)
        XCTAssertEqual(closed.requests, 600)
        let openP95 = Saturating.milliseconds(open.fromIntendedStart.quantile(0.95) ?? .zero)
        let closedP99 = Saturating.milliseconds(closed.fromActualStart.quantile(0.99) ?? .zero)
        XCTAssertGreaterThanOrEqual(openP95, 150, "about 90 requests were scheduled into the stall")
        XCTAssertLessThan(closedP99, 100, "only the two in-flight requests ever saw it")
        XCTAssertEqual(open.labels["ok"], 600)
    }
}
