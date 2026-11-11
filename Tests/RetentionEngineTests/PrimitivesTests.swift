import XCTest
@testable import RetentionEngine

final class PrimitivesTests: XCTestCase {
    func testSaturatingArithmeticNeverTraps() {
        XCTAssertEqual(Saturating.add(Int64.max, 1), .max)
        XCTAssertEqual(Saturating.add(Int64.min, -1), .min)
        XCTAssertEqual(Saturating.subtract(Int64.min, 1), .min)
        XCTAssertEqual(Saturating.subtract(Int64.max, -1), .max)
        XCTAssertEqual(Saturating.subtract(0, Int64.min), .max)
        XCTAssertEqual(Saturating.multiply(Int64.max, 2), .max)
        XCTAssertEqual(Saturating.multiply(Int64.min, -1), .max)
        XCTAssertEqual(Saturating.multiply(Int64.min, 2), .min)
        XCTAssertEqual(Saturating.add(Int.max, 1), .max)
        XCTAssertEqual(Saturating.add(2, 3), 5)
    }

    func testDoubleConversionHandlesNaNInfinityAndRange() {
        XCTAssertEqual(Saturating.int64(.nan), 0)
        XCTAssertEqual(Saturating.int64(.infinity), .max)
        XCTAssertEqual(Saturating.int64(-.infinity), .min)
        XCTAssertEqual(Saturating.int64(1e300), .max)
        XCTAssertEqual(Saturating.int64(-1e300), .min)
        // Double(Int64.max) rounds up past Int64.max; a naive Int64(_:) would trap here.
        XCTAssertEqual(Saturating.int64(Double(Int64.max)), .max)
        XCTAssertEqual(Saturating.int64(42.9), 42)
        XCTAssertEqual(Saturating.int(.nan), 0)
        XCTAssertEqual(Saturating.int(1e300), .max)
    }

    func testDurationConversionsSaturateInsteadOfTrapping() {
        // `Duration.components` traps beyond Int64.max seconds; the helpers clamp first.
        let huge = Duration.seconds(Int64.max) * 8
        XCTAssertEqual(Saturating.microseconds(huge), .max)
        XCTAssertEqual(Saturating.milliseconds(huge), .max)
        XCTAssertEqual(Saturating.microseconds(.zero - huge), .min)
        var histogram = LatencyHistogram()
        histogram.record(huge)
        XCTAssertEqual(histogram.maximumMicroseconds, LatencyHistogram.maximumTrackableMicroseconds)
    }

    func testSystemClocksShareOneOrigin() async throws {
        let early = SystemDeadlineClock()
        try await Task.sleep(for: .milliseconds(20))
        let late = SystemDeadlineClock()
        let difference = early.now() - late.now()
        XCTAssertLessThan(difference, .milliseconds(5), "instances created 20 ms apart must agree on the time")
        XCTAssertGreaterThan(difference, .milliseconds(-5))
    }

    func testDurationConversions() {
        XCTAssertEqual(Saturating.milliseconds(.milliseconds(450)), 450)
        XCTAssertEqual(Saturating.microseconds(.milliseconds(3)), 3_000)
        XCTAssertEqual(Saturating.microseconds(.seconds(2) + .microseconds(5)), 2_000_005)
    }

    /// Published FNV-1a 64-bit test vectors. A `Hasher`-based implementation cannot produce these
    /// (and would differ between processes), so this pins the experiment buckets across deploys.
    func testFNV1aGoldenVectors() {
        XCTAssertEqual(StableHash.fnv1a64(""), 0xcbf2_9ce4_8422_2325)
        XCTAssertEqual(StableHash.fnv1a64("a"), 0xaf63_dc4c_8601_ec8c)
        XCTAssertEqual(StableHash.fnv1a64("foobar"), 0x8594_4171_f739_67e8)
    }

    func testContentUUIDIsVersion8AndPinned() {
        let first = StableHash.contentUUID("header\u{1F}body")
        // Computed independently (Python, FNV-1a 64 + RFC 9562 v8 bits). A per-process hash would
        // produce a different value in every test run, so this pins identity across processes.
        XCTAssertEqual(first, "fd97f36a-1fdc-874a-8321-94f6927246c8")
        XCTAssertNotEqual(first, StableHash.contentUUID("header\u{1F}body!"))
        let characters = Array(first)
        XCTAssertEqual(characters.count, 36)
        XCTAssertEqual(characters[14], "8", "version nibble")
        XCTAssertTrue(["8", "9", "a", "b"].contains(characters[19]), "RFC 9562 variant")
        XCTAssertNotNil(UUID(uuidString: first))
    }

    func testWilsonIntervalKnownValue() throws {
        let interval = try XCTUnwrap(Wilson.interval(successes: 50, trials: 100))
        XCTAssertEqual(interval.lowerBound, 0.403830, accuracy: 0.00001)
        XCTAssertEqual(interval.upperBound, 0.596170, accuracy: 0.00001)
        XCTAssertNil(Wilson.interval(successes: 0, trials: 0))
        XCTAssertNil(Wilson.interval(successes: 1, trials: 10, z: .nan))
        let zero = try XCTUnwrap(Wilson.interval(successes: 0, trials: 20))
        XCTAssertEqual(zero.lowerBound, 0, accuracy: 1e-12)
        XCTAssertGreaterThan(zero.upperBound, 0.1)
        // Out-of-range successes are clamped, not trusted.
        let clamped = try XCTUnwrap(Wilson.interval(successes: 30, trials: 20))
        XCTAssertEqual(clamped.upperBound, 1, accuracy: 1e-12)
    }

    func testNewcombeDifference() throws {
        let difference = try XCTUnwrap(Wilson.differenceInterval(successes1: 30, trials1: 100, successes2: 20, trials2: 100))
        XCTAssertEqual(difference.estimate, 0.10, accuracy: 1e-12)
        XCTAssertLessThan(difference.interval.lowerBound, difference.estimate)
        XCTAssertGreaterThan(difference.interval.upperBound, difference.estimate)
        // Newcombe (1998) method 10 for 30/100 vs 20/100, computed independently: [-0.020252, 0.216736].
        XCTAssertEqual(difference.interval.lowerBound, -0.020252, accuracy: 0.0001)
        XCTAssertEqual(difference.interval.upperBound, 0.216736, accuracy: 0.0001)
        XCTAssertNil(Wilson.differenceInterval(successes1: 1, trials1: 0, successes2: 1, trials2: 1))
    }

    func testExperimentAssignmentIsDeterministicAndClamped() {
        let assigner = ExperimentAssigner(salt: "exp-1", holdoutBasisPoints: 1_000)
        XCTAssertEqual(ExperimentAssigner(salt: "x", holdoutBasisPoints: -5).holdoutBasisPoints, 0)
        XCTAssertEqual(ExperimentAssigner(salt: "x", holdoutBasisPoints: 99_999).holdoutBasisPoints, 10_000)
        let none = ExperimentAssigner(salt: "x", holdoutBasisPoints: 0)
        let all = ExperimentAssigner(salt: "x", holdoutBasisPoints: 10_000)
        for index in 0..<500 {
            XCTAssertEqual(none.arm(for: "s\(index)"), .treatment)
            XCTAssertEqual(all.arm(for: "s\(index)"), .holdout)
            XCTAssertTrue((0..<10_000).contains(assigner.bucket(for: "s\(index)")))
        }
        // Computed independently (Python FNV-1a over "exp-1:2000001000", mod 10,000). If this
        // moves, every subscriber's arm moves with it — a silent re-randomization of the experiment.
        XCTAssertEqual(assigner.bucket(for: "2000001000"), 7_523)
    }

    func testHoldoutBoundaryIsExclusive() throws {
        let zero = ExperimentAssigner(salt: "edge", holdoutBasisPoints: 0)
        let one = ExperimentAssigner(salt: "edge", holdoutBasisPoints: 1)
        // Find a subscriber in bucket 0 (about one in 10,000).
        let inBucketZero = try XCTUnwrap((0..<1_000_000).lazy.map { "s\($0)" }.first { zero.bucket(for: $0) == 0 })
        let inBucketOne = try XCTUnwrap((0..<1_000_000).lazy.map { "s\($0)" }.first { zero.bucket(for: $0) == 1 })
        XCTAssertEqual(zero.arm(for: inBucketZero), .treatment, "0 basis points holds out no one")
        XCTAssertEqual(one.arm(for: inBucketZero), .holdout, "1 basis point holds out exactly bucket 0")
        XCTAssertEqual(one.arm(for: inBucketOne), .treatment)
    }

    func testHoldoutShareIsCloseToConfigured() {
        let assigner = ExperimentAssigner(salt: "share", holdoutBasisPoints: 1_000)
        let holdout = (0..<20_000).filter { assigner.arm(for: "subscriber-\($0)") == .holdout }.count
        XCTAssertEqual(Double(holdout) / 20_000, 0.10, accuracy: 0.01)
    }
}
