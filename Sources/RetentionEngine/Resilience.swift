import Foundation

/// A circuit breaker for the remote feature source.
///
/// Without it, a degraded cache costs every L1 miss a full timeout — p99 becomes the budget —
/// and the retries pile onto a dependency that is already struggling. Open, the engine skips the
/// dependency and serves the safe fallback at once; after `openDuration` a single probe is let
/// through (half-open) and its result decides whether to close again.
public final class DependencyBreaker: Sendable {
    public enum State: Sendable, Hashable {
        case closed(consecutiveFailures: Int)
        case open(until: Duration)
        case halfOpen(probeInFlight: Bool)
    }

    public let failureThreshold: Int
    public let openDuration: Duration
    private let state = Locked(State.closed(consecutiveFailures: 0))

    /// - Parameters:
    ///   - failureThreshold: Consecutive failures that open the breaker, clamped to `>= 1`.
    ///   - openDuration: How long to stay open before probing, clamped to `>= 0`.
    public init(failureThreshold: Int, openDuration: Duration) {
        self.failureThreshold = max(1, failureThreshold)
        self.openDuration = max(.zero, openDuration)
    }

    public var currentState: State { state.withLock { $0 } }

    /// Whether to call the dependency now. In half-open, exactly one caller gets `true`.
    public func shouldAttempt(now: Duration) -> Bool {
        state.withLock { state in
            switch state {
            case .closed:
                return true
            case .open(let until):
                guard now >= until else { return false }
                state = .halfOpen(probeInFlight: true)
                return true
            case .halfOpen(let probeInFlight):
                guard !probeInFlight else { return false }
                state = .halfOpen(probeInFlight: true)
                return true
            }
        }
    }

    public func recordSuccess() {
        state.withLock { $0 = .closed(consecutiveFailures: 0) }
    }

    /// Gives back a half-open probe whose attempt ended without a verdict (its caller was
    /// cancelled). Otherwise the breaker would wait forever for a probe that never reports.
    public func abandonProbe() {
        state.withLock { state in
            if case .halfOpen(probeInFlight: true) = state { state = .halfOpen(probeInFlight: false) }
        }
    }

    public func recordFailure(now: Duration) {
        state.withLock { state in
            switch state {
            case .closed(let failures):
                let next = failures &+ 1
                state = next >= failureThreshold ? .open(until: now + openDuration) : .closed(consecutiveFailures: next)
            case .halfOpen, .open:
                state = .open(until: now + openDuration)
            }
        }
    }
}

/// A bounded cache with a time-to-live, evicting in insertion order.
///
/// Memory is bounded by `capacity` no matter how many distinct keys arrive — the replay cache
/// sits on an internet-facing endpoint, so "unbounded until TTL" is not a bound.
struct BoundedTTLCache<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    private struct Slot: Sendable {
        var value: Value
        var storedAt: Duration
        var ring: Int
    }

    let capacity: Int
    let ttl: Duration
    private var storage: [Key: Slot] = [:]
    private var ring: [Key?]
    private var next = 0

    init(capacity: Int, ttl: Duration) {
        self.capacity = max(1, capacity)
        self.ttl = max(.zero, ttl)
        ring = Array(repeating: nil, count: self.capacity)
    }

    var count: Int { storage.count }

    mutating func value(for key: Key, now: Duration) -> Value? {
        guard let slot = storage[key] else { return nil }
        guard now - slot.storedAt <= ttl else {
            storage[key] = nil
            return nil
        }
        return slot.value
    }

    mutating func insert(_ value: Value, for key: Key, now: Duration) {
        if var slot = storage[key] {
            slot.value = value
            slot.storedAt = now
            storage[key] = slot
            return
        }
        let index = next
        // Evict whatever owns this ring position — but only if it still lives there; a key that
        // expired and was re-inserted owns a newer position and must survive.
        if let evicted = ring[index], storage[evicted]?.ring == index {
            storage[evicted] = nil
        }
        ring[index] = key
        storage[key] = Slot(value: value, storedAt: now, ring: index)
        next = (index + 1) % capacity
    }
}
