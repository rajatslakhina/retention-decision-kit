import Foundation
import RetentionEngine

/// Observed performance of a message variant.
public struct VariantStats: Codable, Sendable, Hashable {
    public let shown: Int
    public let saved: Int

    public init(shown: Int, saved: Int) {
        self.shown = max(0, shown)
        self.saved = min(max(0, saved), max(0, shown))
    }

    private enum CodingKeys: String, CodingKey { case shown, saved }

    /// Decoding goes through the clamping initializer: decoded stats cannot claim more saves than impressions.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(shown: try container.decode(Int.self, forKey: .shown), saved: try container.decode(Int.self, forKey: .saved))
    }
}

/// Orders variants for a catalog cell.
///
/// Proven variants are ranked by the *lower* bound of their Wilson interval, so a variant that
/// went 3-for-3 does not outrank one that went 300-for-1,000. A fixed number of slots is kept for
/// variants with too few impressions to judge, so new copy gets traffic at all.
public struct VariantRanker: Sendable, Hashable {
    public let minimumImpressions: Int
    public let explorationSlots: Int

    public init(minimumImpressions: Int = 200, explorationSlots: Int = 1) {
        self.minimumImpressions = max(1, minimumImpressions)
        self.explorationSlots = max(0, explorationSlots)
    }

    /// - Returns: At most `cap` identifiers, best first. Order among unproven variants is preserved.
    public func rank(_ identifiers: [String], stats: [String: VariantStats], cap: Int) -> [String] {
        let limit = max(0, cap)
        guard limit > 0 else { return [] }
        var seen = Set<String>()
        let unique = identifiers.filter { seen.insert($0).inserted }
        let proven = unique.filter { (stats[$0]?.shown ?? 0) >= minimumImpressions }
        let unproven = unique.filter { (stats[$0]?.shown ?? 0) < minimumImpressions }
        func lowerBound(_ id: String) -> Double {
            guard let s = stats[id], let interval = Wilson.interval(successes: s.saved, trials: s.shown) else { return 0 }
            return interval.lowerBound
        }
        let rankedProven = proven.sorted { lhs, rhs in
            let (l, r) = (lowerBound(lhs), lowerBound(rhs))
            return l != r ? l > r : lhs < rhs
        }
        let exploration = min(explorationSlots, unproven.count, limit)
        let provenTake = min(rankedProven.count, limit - exploration)
        var result = Array(rankedProven.prefix(provenTake)) + Array(unproven.prefix(exploration))
        // Fill any remaining room with whatever is left, proven first.
        for id in rankedProven.dropFirst(provenTake) + unproven.dropFirst(exploration) where result.count < limit {
            result.append(id)
        }
        return result
    }
}

/// A message Apple has not seen yet.
public struct MessageUpload: Codable, Sendable, Hashable {
    public let messageIdentifier: String
    public let header: String
    public let body: String
}

public struct CompileResult: Sendable {
    /// What the hot path will load. Every message it can return — ranked entries, safe fallbacks
    /// and control messages — is `APPROVED`.
    public let catalog: MessageCatalog
    /// Messages to upload (unknown to Apple). Content-addressed, so re-running is safe.
    public let uploads: [MessageUpload]
    /// Publishable drafts still waiting for App Review (or not yet uploaded).
    public let awaitingApproval: [VariantDraft]
    /// Drafts dropped, with the reason.
    public let dropped: [(draft: VariantDraft, reason: String)]
}

public enum CompileError: Error, Sendable, Hashable {
    /// Apple allows at most 2,000 messages per app.
    case appMessageLimitExceeded(count: Int)
    /// A safe-fallback or control message is not `APPROVED`. Apple displays only approved messages,
    /// so serving it would silently become Apple's own default. `uploads` lists the ones Apple has
    /// never seen (when their copy was supplied) so the caller can upload them and retry.
    case fallbacksNotApproved(messageIdentifiers: [String], uploads: [MessageUpload])
    case catalog(CatalogError)
}

/// Turns gated drafts plus Apple's approval states into the catalog the hot path reads.
public struct CatalogCompiler: Sendable {
    /// Apple's Upload Message limit: "The maximum number of messages you can configure for each app is 2000."
    public static let appleMessageLimit = 2_000

    /// Our own cap per (product, locale, segment) — enough for a ranked list plus fallbacks, few
    /// enough that each variant collects impressions. Not an Apple limit. Clamped to `1...10`.
    public let perCellCap: Int
    public let ranker: VariantRanker

    public init(perCellCap: Int = 4, ranker: VariantRanker = VariantRanker()) {
        self.perCellCap = min(max(perCellCap, 1), 10)
        self.ranker = ranker
    }

    /// - Parameters:
    ///   - states: Apple's `messageState` for every message it knows (from Get Message List).
    ///   - productLocales: The human-owned safe-fallback and control message for each product/locale.
    ///     Each must be `APPROVED` or compilation fails.
    ///   - fallbackCopy: Header and body for fallback/control messages, keyed by identifier, so that
    ///     any Apple has never seen can be included in the upload plan.
    public func compile(
        drafts: [VariantDraft],
        states: [String: MessageState],
        productLocales: [ProductLocaleMessages],
        fallbackCopy: [String: CopyCandidate] = [:],
        stats: [String: VariantStats] = [:],
        primaryLocale: String
    ) throws -> CompileResult {
        // The hot path's last resort must itself be displayable, or "fail safe" means "fail to Apple's default".
        var unapproved: [String] = []
        var fallbackUploads: [MessageUpload] = []
        var seenFallbacks = Set<String>()
        for messages in productLocales {
            for id in [messages.safeFallbackMessageId, messages.controlMessageId] where seenFallbacks.insert(id).inserted {
                guard states[id] != .approved else { continue }
                unapproved.append(id)
                if states[id] == nil, let copy = fallbackCopy[id] {
                    fallbackUploads.append(MessageUpload(messageIdentifier: id, header: copy.header, body: copy.body))
                }
            }
        }
        guard unapproved.isEmpty else {
            throw CompileError.fallbacksNotApproved(messageIdentifiers: unapproved, uploads: fallbackUploads)
        }

        var dropped: [(draft: VariantDraft, reason: String)] = []
        var publishable: [VariantDraft] = []
        var seenInCell = Set<String>()
        for draft in drafts {
            if !draft.verdict.passed {
                dropped.append((draft, "gate: " + draft.verdict.blockingRuleIds.joined(separator: ", ")))
                continue
            }
            if let veto = draft.judgeVeto {
                dropped.append((draft, "judge: " + veto))
                continue
            }
            let cellKey = "\(draft.brief.catalogKey.productId)|\(draft.brief.catalogKey.locale)|\(draft.brief.segment.rawValue)|\(draft.variantId)"
            guard seenInCell.insert(cellKey).inserted else {
                dropped.append((draft, "duplicate in cell"))
                continue
            }
            publishable.append(draft)
        }

        // Apple's 2,000-message ceiling counts everything the app has, not just this run.
        var allIdentifiers = Set(states.keys)
        for draft in publishable { allIdentifiers.insert(draft.messageIdentifier) }
        for messages in productLocales {
            allIdentifiers.insert(messages.safeFallbackMessageId)
            allIdentifiers.insert(messages.controlMessageId)
        }
        guard allIdentifiers.count <= Self.appleMessageLimit else {
            throw CompileError.appMessageLimitExceeded(count: allIdentifiers.count)
        }

        var uploads: [MessageUpload] = []
        var uploaded = Set<String>()
        var awaiting: [VariantDraft] = []
        var approvedByCell: [CatalogKey: [VariantDraft]] = [:]
        for draft in publishable {
            switch states[draft.messageIdentifier] {
            case .approved?:
                approvedByCell[draft.brief.catalogKey, default: []].append(draft)
            case .pending?:
                awaiting.append(draft)
            case .rejected?:
                dropped.append((draft, "App Review rejected the message"))
            case nil:
                if uploaded.insert(draft.messageIdentifier).inserted {
                    uploads.append(MessageUpload(
                        messageIdentifier: draft.messageIdentifier,
                        header: draft.candidate.header,
                        body: draft.candidate.body
                    ))
                }
                awaiting.append(draft)
            }
        }

        var entries: [CatalogKey: [CatalogEntry]] = [:]
        for (key, cellDrafts) in approvedByCell {
            // Rank *within* each kind, then concatenate offer → switch plan → text. The hot path
            // returns the first usable entry and text is always usable, so ranking across kinds
            // could put a text message first and make every offer behind it unreachable.
            let order = [0, 1, 2].flatMap { kindRank in
                ranker.rank(
                    cellDrafts.filter { Self.kindRank($0.brief.kind) == kindRank }.map(\.variantId),
                    stats: stats,
                    cap: perCellCap
                )
            }.prefix(perCellCap).map { $0 }
            let byVariant = Dictionary(cellDrafts.map { ($0.variantId, $0) }, uniquingKeysWith: { first, _ in first })
            entries[key] = order.compactMap { variant in
                byVariant[variant].map {
                    CatalogEntry(messageIdentifier: $0.messageIdentifier, variantId: variant, kind: $0.brief.kind)
                }
            }
            for draft in cellDrafts where !order.contains(draft.variantId) {
                dropped.append((draft, "below the per-cell cap of \(perCellCap)"))
            }
        }

        do {
            let catalog = try MessageCatalog(primaryLocale: primaryLocale, entries: entries, productLocales: productLocales)
            return CompileResult(catalog: catalog, uploads: uploads, awaitingApproval: awaiting, dropped: dropped)
        } catch let error as CatalogError {
            throw CompileError.catalog(error)
        }
    }

    static func kindRank(_ kind: MessageKind) -> Int {
        switch kind {
        case .promotionalOffer: return 0
        case .switchPlan: return 1
        case .text: return 2
        }
    }
}
