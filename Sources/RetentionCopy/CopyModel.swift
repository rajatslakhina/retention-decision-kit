import Foundation
import RetentionEngine

/// What one cell of the catalog needs: who it is for, what kind of message, and the only facts
/// the copy may rely on.
public struct CopyBrief: Codable, Sendable, Hashable {
    public let productId: String
    public let productName: String
    public let locale: String
    public let segment: Segment
    public let kind: MessageKind
    /// For a promotional offer: the discount the offer really gives. The copy may state exactly this
    /// percentage or none at all.
    public let offerDiscountPercent: Int?
    /// Grounding. Any number in the copy must appear here (or be the offer's discount).
    public let valuePoints: [String]
    /// Variants to draft, clamped to `1...6`.
    public let variantCount: Int

    public init(
        productId: String,
        productName: String,
        locale: String,
        segment: Segment,
        kind: MessageKind,
        offerDiscountPercent: Int? = nil,
        valuePoints: [String],
        variantCount: Int = 3
    ) {
        self.productId = productId
        self.productName = productName
        self.locale = LocaleChain.normalize(locale)
        self.segment = segment
        self.kind = kind
        if case .promotionalOffer = kind, let percent = offerDiscountPercent {
            self.offerDiscountPercent = min(max(percent, 1), 100)
        } else {
            self.offerDiscountPercent = nil
        }
        self.valuePoints = valuePoints
        self.variantCount = min(max(variantCount, 1), 6)
    }

    private enum CodingKeys: String, CodingKey {
        case productId, productName, locale, segment, kind, offerDiscountPercent, valuePoints, variantCount
    }

    /// Decoding goes through the normalizing initializer, so a brief loaded from a file is held to the same rules.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            productId: try container.decode(String.self, forKey: .productId),
            productName: try container.decode(String.self, forKey: .productName),
            locale: try container.decode(String.self, forKey: .locale),
            segment: try container.decode(Segment.self, forKey: .segment),
            kind: try container.decode(MessageKind.self, forKey: .kind),
            offerDiscountPercent: try container.decodeIfPresent(Int.self, forKey: .offerDiscountPercent),
            valuePoints: try container.decode([String].self, forKey: .valuePoints),
            variantCount: try container.decode(Int.self, forKey: .variantCount)
        )
    }

    public var catalogKey: CatalogKey { CatalogKey(productId: productId, locale: locale, segment: segment) }
}

/// A drafted message: Apple's Upload Message `header` and `body`.
public struct CopyCandidate: Codable, Sendable, Hashable {
    public let header: String
    public let body: String
    /// The drafter's stated reason. Logged, never shown to subscribers.
    public let rationale: String?

    public init(header: String, body: String, rationale: String? = nil) {
        self.header = header
        self.body = body
        self.rationale = rationale
    }

    /// Content-addressed message identifier: the same header and body always map to the same
    /// identifier, so re-running the pipeline never uploads a duplicate.
    public var messageIdentifier: String {
        StableHash.contentUUID("message.v1\u{1F}" + header + "\u{1F}" + body)
    }
}

/// Apple's review state for an uploaded message (`messageState`).
public enum MessageState: String, Codable, Sendable, Hashable {
    case pending = "PENDING"
    case approved = "APPROVED"
    case rejected = "REJECTED"
}

/// A candidate after the gate, ready for the compiler.
public struct VariantDraft: Sendable, Hashable {
    public let brief: CopyBrief
    public let candidate: CopyCandidate
    public let verdict: CopyVerdict
    public let judgeVeto: String?

    public init(brief: CopyBrief, candidate: CopyCandidate, verdict: CopyVerdict, judgeVeto: String? = nil) {
        self.brief = brief
        self.candidate = candidate
        self.verdict = verdict
        self.judgeVeto = judgeVeto
    }

    public var messageIdentifier: String { candidate.messageIdentifier }
    /// One Apple message can back several kinds (the same text with or without an offer attached),
    /// so a variant is the message *and* the kind it is served as. Stats are keyed by this.
    public var variantId: String { messageIdentifier + "#" + brief.kind.canonical }
    public var isPublishable: Bool { verdict.passed && judgeVeto == nil }
}
