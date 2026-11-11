import Foundation

/// The remote (L2) feature source — a cache cluster, a database replica, another service.
///
/// The engine assumes nothing about it: it may be slow, it may fail, and it may ignore
/// cancellation entirely. Every call is raced against the response budget.
public protocol FeatureSource: Sendable {
    func features(for originalTransactionId: String) async throws -> SubscriberFeatures?
}

/// The in-process (L1) feature store: precomputed per-subscriber features keyed by
/// `originalTransactionId`, kept current by App Store Server Notifications.
///
/// Sharded with one lock per shard. A read is one dictionary lookup under one shard's lock; a
/// write is one merge under one shard's lock. Batch ingestion releases the lock between facts, so
/// a ten-thousand-notification backfill never makes a request wait for more than one merge.
public final class FeatureStore: Sendable {
    private let shards: [Locked<[String: SubscriberFeatures]>]

    /// - Parameter shardCount: Clamped to `1...1024`.
    public init(shardCount: Int = 16) {
        let count = min(max(shardCount, 1), 1024)
        shards = (0..<count).map { _ in Locked([:]) }
    }

    private func shard(for originalTransactionId: String) -> Locked<[String: SubscriberFeatures]> {
        // `shards` is never empty (count >= 1), and the remainder is < shards.count.
        let index = Int(StableHash.fnv1a64(originalTransactionId) % UInt64(shards.count))
        return shards[index]
    }

    /// O(1). Never suspends.
    public func features(for originalTransactionId: String) -> SubscriberFeatures? {
        shard(for: originalTransactionId).withLock { $0[originalTransactionId] }
    }

    /// Folds one fact into the store and returns the subscriber's new state.
    @discardableResult
    public func ingest(_ fact: SubscriptionFact) -> SubscriberFeatures {
        shard(for: fact.originalTransactionId).withLock { table in
            var features = table[fact.originalTransactionId]
                ?? SubscriberFeatures(originalTransactionId: fact.originalTransactionId)
            features.merge(fact)
            table[fact.originalTransactionId] = features
            return features
        }
    }

    /// Folds facts one at a time (one critical section each). Returns how many were applied.
    @discardableResult
    public func ingest<Facts: Sequence>(_ facts: Facts) -> Int where Facts.Element == SubscriptionFact {
        var applied = 0
        for fact in facts {
            ingest(fact)
            applied += 1
        }
        return applied
    }

    /// Joins an externally obtained state (for example an L2 hit) into the store.
    public func upsert(_ features: SubscriberFeatures) {
        shard(for: features.originalTransactionId).withLock { table in
            if var existing = table[features.originalTransactionId] {
                existing.merge(features)
                table[features.originalTransactionId] = existing
            } else {
                table[features.originalTransactionId] = features
            }
        }
    }

    public var count: Int {
        shards.reduce(0) { total, shard in total + shard.withLock { $0.count } }
    }

    /// Drops subscribers whose subscription ended (expired, refunded, revoked) before `cutoff`
    /// (UNIX milliseconds, Apple's clock). Without this the store holds one record — about 1 KB
    /// resident (measured on Linux with three to five facts per subscriber) — for every subscriber
    /// it has ever seen. Run it periodically, for example
    /// daily with a cutoff of "now minus the attribution window". Compaction forgets history: a
    /// subscriber who returns later starts with a fresh record (tenure and redemption history
    /// reset), so choose a cutoff longer than your offer cool-down. Returns how many were removed.
    @discardableResult
    public func compact(inactiveBefore cutoff: Int64) -> Int {
        shards.reduce(0) { removed, shard in
            removed + shard.withLock { table -> Int in
                let stale = table.filter { _, features in
                    guard let active = features.isActive, active.value == false else { return false }
                    return active.clock.signedDate < cutoff
                }
                for key in stale.keys { table[key] = nil }
                return stale.count
            }
        }
    }
}
