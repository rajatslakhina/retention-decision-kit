import Foundation

/// What a catalog entry asks Apple to show.
public enum MessageKind: Codable, Sendable, Hashable {
    /// Text (optionally with an image). The only kind Apple allows as a default message.
    case text
    /// Switch-plan: the alternate product must be in the same subscription group.
    case switchPlan(alternateProductId: String)
    /// Promotional offer configured in App Store Connect; the server signs it per request.
    case promotionalOffer(offerId: String)

    /// A stable textual form, used for fingerprints (never `String(describing:)`).
    public var canonical: String {
        switch self {
        case .text: return "text"
        case .switchPlan(let product): return "switch:" + product
        case .promotionalOffer(let offer): return "offer:" + offer
        }
    }
}

/// One approved message, ranked offline for a (product, locale, segment).
public struct CatalogEntry: Codable, Sendable, Hashable {
    /// Apple's `messageIdentifier`. Must be in the `APPROVED` state.
    public let messageIdentifier: String
    /// The offline variant this came from, for attribution and experiment analysis.
    public let variantId: String
    public let kind: MessageKind

    public init(messageIdentifier: String, variantId: String, kind: MessageKind) {
        self.messageIdentifier = messageIdentifier
        self.variantId = variantId
        self.kind = kind
    }
}

public struct CatalogKey: Codable, Sendable, Hashable, Comparable {
    public let productId: String
    public let locale: String
    public let segment: Segment

    public init(productId: String, locale: String, segment: Segment) {
        self.productId = productId
        self.locale = LocaleChain.normalize(locale)
        self.segment = segment
    }

    public static func < (lhs: CatalogKey, rhs: CatalogKey) -> Bool {
        (lhs.productId, lhs.locale, lhs.segment.rawValue) < (rhs.productId, rhs.locale, rhs.segment.rawValue)
    }

    private enum CodingKeys: String, CodingKey { case productId, locale, segment }

    /// Decoding goes through the normalizing initializer: a key written as `en_us` is `en-US`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            productId: try container.decode(String.self, forKey: .productId),
            locale: try container.decode(String.self, forKey: .locale),
            segment: try container.decode(Segment.self, forKey: .segment)
        )
    }
}

/// Human-owned, approved messages that make the hot path fail safe for a (product, locale).
public struct ProductLocaleMessages: Codable, Sendable, Hashable {
    public let productId: String
    public let locale: String
    /// A text-only message that is correct for every subscriber of the product. Served whenever the
    /// personalized path cannot finish inside the budget.
    public let safeFallbackMessageId: String
    /// The message the holdout arm sees.
    public let controlMessageId: String

    public init(productId: String, locale: String, safeFallbackMessageId: String, controlMessageId: String) {
        self.productId = productId
        self.locale = LocaleChain.normalize(locale)
        self.safeFallbackMessageId = safeFallbackMessageId
        self.controlMessageId = controlMessageId
    }

    private enum CodingKeys: String, CodingKey { case productId, locale, safeFallbackMessageId, controlMessageId }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            productId: try container.decode(String.self, forKey: .productId),
            locale: try container.decode(String.self, forKey: .locale),
            safeFallbackMessageId: try container.decode(String.self, forKey: .safeFallbackMessageId),
            controlMessageId: try container.decode(String.self, forKey: .controlMessageId)
        )
    }
}

public enum CatalogError: Error, Sendable, Hashable {
    /// Entries exist for a product/locale that has no safe fallback — the hot path could not fail safe.
    case missingFallback(productId: String, locale: String)
    case emptyMessageIdentifier
    case switchPlanToSameProduct(productId: String)
}

/// Locale normalization and the fallback chain, mirroring Apple's "next most relevant" behaviour
/// for default messages: exact tag, then progressively shorter tags, then the primary locale.
public enum LocaleChain {
    /// `en_us` → `en-US`, `zh-hans-cn` → `zh-Hans-CN`.
    public static func normalize(_ locale: String) -> String {
        let parts = locale.replacingOccurrences(of: "_", with: "-")
            .split(separator: "-", omittingEmptySubsequences: true)
        guard let language = parts.first else { return "" }
        var normalized = [language.lowercased()]
        for part in parts.dropFirst() {
            switch part.count {
            case 2 where part.allSatisfy(\.isLetter): normalized.append(part.uppercased())
            case 4 where part.allSatisfy(\.isLetter): normalized.append(part.prefix(1).uppercased() + part.dropFirst().lowercased())
            default: normalized.append(String(part))
            }
        }
        return normalized.joined(separator: "-")
    }

    public static func chain(for locale: String, primary: String) -> [String] {
        var subtags = normalize(locale).split(separator: "-").map(String.init)
        var result: [String] = []
        while !subtags.isEmpty {
            result.append(subtags.joined(separator: "-"))
            subtags.removeLast()
        }
        let normalizedPrimary = normalize(primary)
        if !normalizedPrimary.isEmpty { result.append(normalizedPrimary) }
        var seen = Set<String>()
        return result.filter { seen.insert($0).inserted }
    }
}

/// The compiled, immutable artifact the offline pipeline publishes and the hot path reads.
///
/// The LLM never runs inside the 700 ms window: it runs offline, its output is gated and
/// approved by Apple, and what reaches the request path is this lookup table.
public struct MessageCatalog: Sendable, Hashable {
    public let version: String
    public let primaryLocale: String
    private let ranked: [CatalogKey: [CatalogEntry]]
    private let productLocales: [String: ProductLocaleMessages]

    public init(primaryLocale: String, entries: [CatalogKey: [CatalogEntry]], productLocales: [ProductLocaleMessages]) throws {
        let primary = LocaleChain.normalize(primaryLocale)
        var table: [String: ProductLocaleMessages] = [:]
        for messages in productLocales {
            guard !messages.safeFallbackMessageId.isEmpty, !messages.controlMessageId.isEmpty else {
                throw CatalogError.emptyMessageIdentifier
            }
            table[Self.productLocaleKey(messages.productId, messages.locale)] = messages
        }
        for (key, list) in entries {
            for entry in list {
                guard !entry.messageIdentifier.isEmpty else { throw CatalogError.emptyMessageIdentifier }
                if case .switchPlan(let alternate) = entry.kind, alternate == key.productId {
                    throw CatalogError.switchPlanToSameProduct(productId: alternate)
                }
            }
            let reachable = LocaleChain.chain(for: key.locale, primary: primary).contains {
                table[Self.productLocaleKey(key.productId, $0)] != nil
            }
            guard reachable else { throw CatalogError.missingFallback(productId: key.productId, locale: key.locale) }
        }
        self.primaryLocale = primary
        self.ranked = entries
        self.productLocales = table
        self.version = Self.fingerprint(primary: primary, entries: entries, productLocales: table)
    }

    /// An empty catalog: every request defers to Apple's own fallback.
    public static let empty: MessageCatalog = {
        // Provably non-throwing: with no entries there is nothing for validation to reject.
        try! MessageCatalog(primaryLocale: "en-US", entries: [:], productLocales: [])
    }()

    private static func productLocaleKey(_ productId: String, _ locale: String) -> String {
        productId + "\u{1F}" + LocaleChain.normalize(locale)
    }

    /// Ranked entries for the first locale in the chain that has any, and that locale.
    public func candidates(productId: String, locale: String, segment: Segment) -> (locale: String, entries: [CatalogEntry])? {
        for candidate in LocaleChain.chain(for: locale, primary: primaryLocale) {
            if let entries = ranked[CatalogKey(productId: productId, locale: candidate, segment: segment)], !entries.isEmpty {
                return (candidate, entries)
            }
        }
        return nil
    }

    public func productLocaleMessages(productId: String, locale: String) -> ProductLocaleMessages? {
        for candidate in LocaleChain.chain(for: locale, primary: primaryLocale) {
            if let messages = productLocales[Self.productLocaleKey(productId, candidate)] { return messages }
        }
        return nil
    }

    public var keys: [CatalogKey] { ranked.keys.sorted() }
    public func entries(for key: CatalogKey) -> [CatalogEntry] { ranked[key] ?? [] }
    public var entryCount: Int { ranked.values.reduce(0) { $0 + $1.count } }

    private static func fingerprint(
        primary: String,
        entries: [CatalogKey: [CatalogEntry]],
        productLocales: [String: ProductLocaleMessages]
    ) -> String {
        var canonical = "primary=\(primary)\n"
        for key in entries.keys.sorted() {
            canonical += "\(key.productId)|\(key.locale)|\(key.segment.rawValue)="
            canonical += (entries[key] ?? []).map { "\($0.messageIdentifier):\($0.variantId):\($0.kind.canonical)" }.joined(separator: ",")
            canonical += "\n"
        }
        for key in productLocales.keys.sorted() {
            if let messages = productLocales[key] {
                canonical += "fallback \(key)=\(messages.safeFallbackMessageId)/\(messages.controlMessageId)\n"
            }
        }
        let hash = StableHash.fnv1a64(canonical)
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }
}

extension MessageCatalog: Codable {
    private enum CodingKeys: String, CodingKey { case primaryLocale, entries, productLocales }

    private struct KeyedEntries: Codable {
        let key: CatalogKey
        let entries: [CatalogEntry]
    }

    /// Decoding re-runs validation: a catalog read from disk is held to the same rules as one
    /// built in memory, so a hand-edited file cannot remove the hot path's ability to fail safe.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let primary = try container.decode(String.self, forKey: .primaryLocale)
        let keyed = try container.decode([KeyedEntries].self, forKey: .entries)
        let messages = try container.decode([ProductLocaleMessages].self, forKey: .productLocales)
        var entries: [CatalogKey: [CatalogEntry]] = [:]
        for item in keyed { entries[item.key, default: []].append(contentsOf: item.entries) }
        try self.init(primaryLocale: primary, entries: entries, productLocales: messages)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(primaryLocale, forKey: .primaryLocale)
        try container.encode(keys.map { KeyedEntries(key: $0, entries: entries(for: $0)) }, forKey: .entries)
        let messages = productLocales.keys.sorted().compactMap { productLocales[$0] }
        try container.encode(messages, forKey: .productLocales)
    }
}

/// Holds the live catalog. Publishing swaps one reference; each request takes one snapshot and
/// uses it throughout, so no request ever sees half an old catalog and half a new one.
public final class CatalogHolder: Sendable {
    private let current: Locked<MessageCatalog>

    public init(_ catalog: MessageCatalog) {
        current = Locked(catalog)
    }

    public func snapshot() -> MessageCatalog {
        current.withLock { $0 }
    }

    public func publish(_ catalog: MessageCatalog) {
        current.withLock { $0 = catalog }
    }
}
