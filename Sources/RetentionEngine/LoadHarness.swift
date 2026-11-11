import Foundation

/// One request issued by the load harness.
public struct LoadSample: Sendable, Hashable {
    public let index: Int
    /// When the schedule said the request should start.
    public let intendedStart: Duration
    /// When it actually started.
    public let actualStart: Duration
    public let end: Duration
    public let label: String
}

/// What the harness tells the operation about the request it is issuing.
public struct LoadContext: Sendable, Hashable {
    public let index: Int
    /// When the schedule said this request starts. Pass it to the handler as the arrival time, so
    /// time spent queued behind a stall is charged to the response budget — as it would be if
    /// arrival were stamped at the socket.
    public let intendedStart: Duration
}

public struct LoadReport: Sendable {
    public enum Mode: String, Sendable, Hashable {
        /// Requests start on a fixed schedule regardless of how earlier ones are doing — like Apple's
        /// traffic, which does not slow down because your server did.
        case openLoop
        /// N workers, each sending its next request only after the previous one returned.
        case closedLoop
    }

    public let mode: Mode
    public let requests: Int
    /// Latency measured from the intended start. For an open-loop run this is the honest number:
    /// it includes the time a request spent waiting behind a stall.
    public let fromIntendedStart: LatencyHistogram
    /// Latency measured from the actual start — what a closed-loop harness reports.
    public let fromActualStart: LatencyHistogram
    /// Requests whose latency from intended start exceeded Apple's 700 ms timeout.
    public let lateAgainstApple: Int
    public let labels: [String: Int]
    public let wallTime: Duration
}

/// Open- and closed-loop load generation.
///
/// A closed-loop harness under-reports tail latency (coordinated omission): during a stall
/// each worker records one slow request and then simply stops sending, so the hundreds of requests
/// real traffic would have sent into the stall are never measured. The open-loop harness keeps the
/// schedule and measures from the intended start, so a stall shows up in p99 the way subscribers
/// would feel it.
public enum LoadHarness {
    public static let maximumRequests = 200_000

    /// The intended start offset of request `index` at `ratePerSecond`.
    public static func intendedOffset(index: Int, ratePerSecond: Double) -> Duration {
        let rate = clampedRate(ratePerSecond)
        let position = Double(min(max(index, 0), maximumRequests))
        return .seconds(position / rate)
    }

    static func clampedRate(_ rate: Double) -> Double {
        guard rate.isFinite, rate > 0 else { return 1 }
        return min(max(rate, 0.001), 1_000_000)
    }

    public static func runOpenLoop(
        requests: Int,
        ratePerSecond: Double,
        clock: any DeadlineClock,
        operation: @escaping @Sendable (LoadContext) async -> String
    ) async -> LoadReport {
        let total = min(max(requests, 1), maximumRequests)
        let rate = clampedRate(ratePerSecond)
        let origin = clock.now()
        let samples = await withTaskGroup(of: LoadSample.self, returning: [LoadSample].self) { group in
            for index in 0..<total {
                if Task.isCancelled { break }
                let intended = origin + intendedOffset(index: index, ratePerSecond: rate)
                try? await clock.sleep(until: intended)
                group.addTask {
                    let actual = clock.now()
                    let label = await operation(LoadContext(index: index, intendedStart: intended))
                    return LoadSample(index: index, intendedStart: intended, actualStart: actual, end: clock.now(), label: label)
                }
            }
            var collected: [LoadSample] = []
            collected.reserveCapacity(total)
            for await sample in group { collected.append(sample) }
            return collected
        }
        return report(.openLoop, samples: samples, wallTime: clock.now() - origin)
    }

    public static func runClosedLoop(
        requests: Int,
        workers: Int,
        clock: any DeadlineClock,
        operation: @escaping @Sendable (LoadContext) async -> String
    ) async -> LoadReport {
        let total = min(max(requests, 1), maximumRequests)
        let workerCount = min(max(workers, 1), 1_024)
        let origin = clock.now()
        let nextIndex = Locked(0)
        let samples = await withTaskGroup(of: [LoadSample].self, returning: [LoadSample].self) { group in
            for _ in 0..<workerCount {
                group.addTask {
                    var local: [LoadSample] = []
                    while !Task.isCancelled {
                        let index = nextIndex.withLock { next -> Int in
                            defer { next += 1 }
                            return next
                        }
                        guard index < total else { break }
                        // Closed loop has no schedule: "intended" is simply when the worker got around to it.
                        let start = clock.now()
                        let label = await operation(LoadContext(index: index, intendedStart: start))
                        local.append(LoadSample(index: index, intendedStart: start, actualStart: start, end: clock.now(), label: label))
                    }
                    return local
                }
            }
            var collected: [LoadSample] = []
            collected.reserveCapacity(total)
            for await batch in group { collected.append(contentsOf: batch) }
            return collected
        }
        return report(.closedLoop, samples: samples, wallTime: clock.now() - origin)
    }

    static func report(_ mode: LoadReport.Mode, samples: [LoadSample], wallTime: Duration) -> LoadReport {
        var intended = LatencyHistogram()
        var actual = LatencyHistogram()
        var labels: [String: Int] = [:]
        var late = 0
        for sample in samples {
            let fromIntended = sample.end - sample.intendedStart
            intended.record(fromIntended)
            actual.record(sample.end - sample.actualStart)
            labels[sample.label, default: 0] += 1
            if fromIntended > EngineConfiguration.appleTimeout { late += 1 }
        }
        return LoadReport(
            mode: mode,
            requests: samples.count,
            fromIntendedStart: intended,
            fromActualStart: actual,
            lateAgainstApple: late,
            labels: labels,
            wallTime: wallTime
        )
    }
}
