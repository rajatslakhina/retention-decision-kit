import Foundation
import RetentionCopy
import RetentionEngine

/// A subscriber the lab can send to the cancellation sheet.
public struct LabPersona: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let summary: String
    public let originalTransactionId: String
    public let productId: String
    public let locale: String
    /// `false` means the hot path has never seen this subscriber and must ask the remote source.
    public let inLocalStore: Bool
}

/// The demo's world: products, a catalog compiled by the offline pipeline, and personas.
///
/// Everything is deterministic for a given configuration: the same salt yields the same
/// persona IDs, the same drafts, the same catalog version.
public struct LabWorld: Sendable {
    public static let proMonthly = "com.example.notes.pro.monthly"
    public static let proYearly = "com.example.notes.pro.yearly"
    public static let liteMonthly = "com.example.notes.lite.monthly"
    public static let locales = ["en-US", "fr", "de-DE", "ja-JP"]
    public static let offerDiscountPercent = 50
    /// 2026-11-10T00:00:00Z — every request in the lab is "signed" relative to this instant.
    public static let epoch: Int64 = 1_794_268_800_000
    static let day: Int64 = 86_400_000

    public let configuration: EngineConfiguration
    public let catalog: MessageCatalog
    public let pipelineReport: PipelineReport
    public let compileResult: CompileResult
    /// Header and body for every message identifier the catalog can return, for rendering.
    public let messageCopy: [String: CopyCandidate]
    public let personas: [LabPersona]
    public let seedFacts: [SubscriptionFact]

    public static func productName(_ productId: String) -> String {
        switch productId {
        case proYearly: return "Notes Pro (yearly)"
        case liteMonthly: return "Notes Lite"
        default: return "Notes Pro"
        }
    }

    static func offerId(for productId: String) -> String {
        productId == proYearly ? "pro_yearly_retention_50" : "pro_monthly_retention_50"
    }

    static func valuePoints(locale: String, includeOffer: Bool) -> [String] {
        var points: [String]
        switch locale.prefix(2) {
        case "fr": points = ["projets illimités", "mode hors ligne"]
        case "de": points = ["unbegrenzte Projekte", "Offline-Modus"]
        case "ja": points = ["無制限のプロジェクト", "オフラインモード"]
        default: points = ["unlimited projects and offline mode", "sync across iPhone, iPad and Mac"]
        }
        if includeOffer { points.append("Offer: 3 months at \(offerDiscountPercent)% off") }
        return points
    }

    /// The briefs the offline pipeline drafts for: every product, locale and segment, with the
    /// message kinds that make sense for that segment.
    public static func briefs() -> [CopyBrief] {
        var briefs: [CopyBrief] = []
        for product in [proMonthly, proYearly] {
            for locale in locales {
                for segment in Segment.allCases {
                    var kinds: [MessageKind] = []
                    switch segment {
                    case .loyal, .established:
                        kinds = [.promotionalOffer(offerId: offerId(for: product)), .switchPlan(alternateProductId: liteMonthly), .text]
                    case .new:
                        kinds = [.switchPlan(alternateProductId: liteMonthly), .text]
                    case .trial, .billingRetry:
                        kinds = [.text]
                    }
                    for kind in kinds {
                        let isOffer: Bool = { if case .promotionalOffer = kind { return true } else { return false } }()
                        briefs.append(CopyBrief(
                            productId: product,
                            productName: productName(product),
                            locale: locale,
                            segment: segment,
                            kind: kind,
                            offerDiscountPercent: isOffer ? offerDiscountPercent : nil,
                            valuePoints: valuePoints(locale: locale, includeOffer: isOffer),
                            variantCount: 2
                        ))
                    }
                }
            }
        }
        return briefs
    }

    /// Human-written, human-approved safe-fallback and control copy for each product and locale.
    static func fallbackCopy(locale: String) -> (safe: CopyCandidate, control: CopyCandidate) {
        switch locale.prefix(2) {
        case "fr":
            return (CopyCandidate(header: "Nous aimerions vous garder", body: "Votre abonnement synchronise tous vos projets sur vos appareils."),
                    CopyCandidate(header: "Merci d'être abonné", body: "Vous pouvez gérer votre abonnement à tout moment."))
        case "de":
            return (CopyCandidate(header: "Wir würden dich gern behalten", body: "Dein Abo hält alle Projekte auf deinen Geräten synchron."),
                    CopyCandidate(header: "Danke für dein Abo", body: "Du kannst dein Abo jederzeit verwalten."))
        case "ja":
            return (CopyCandidate(header: "引き続きご利用ください", body: "サブスクリプションで、すべてのプロジェクトがデバイス間で同期されます。"),
                    CopyCandidate(header: "ご利用ありがとうございます", body: "サブスクリプションはいつでも管理できます。"))
        default:
            return (CopyCandidate(header: "We'd love you to stay", body: "Your subscription keeps every project in sync across your devices."),
                    CopyCandidate(header: "Thanks for subscribing", body: "You can manage your subscription at any time."))
        }
    }

    /// Simulated Apple state: about one publishable message in nine has not been uploaded yet
    /// (`nil`), one in seven is still `PENDING` review, the rest are `APPROVED`.
    /// (In the sandbox Apple approves everything immediately.)
    static func simulatedState(for identifier: String) -> MessageState? {
        let hash = StableHash.fnv1a64("review:" + identifier)
        if hash % 9 == 0 { return nil }
        return hash % 7 == 0 ? .pending : .approved
    }

    /// Finds the first `prefix<n>` identifier that the experiment puts in `arm`.
    public static func identifier(prefix: String, landingIn arm: Arm, assigner: ExperimentAssigner, start: Int = 0) -> String {
        var candidate = start
        while candidate < start + 100_000 {
            let id = prefix + String(candidate)
            if assigner.arm(for: id) == arm { return id }
            candidate += 1
        }
        // Only reachable with a 0% or 100% holdout, where `arm` cannot occur: fall back to the prefix.
        return prefix + String(start)
    }

    public static func make(configuration: EngineConfiguration) async throws -> LabWorld {
        let pipeline = CopyPipeline(drafter: ScriptedCopyDrafter(includeKnownBadVariants: true))
        let report = await pipeline.run(briefs())

        var productLocales: [ProductLocaleMessages] = []
        var copy: [String: CopyCandidate] = [:]
        for product in [proMonthly, proYearly] {
            for locale in locales {
                let (safe, control) = fallbackCopy(locale: locale)
                copy[safe.messageIdentifier] = safe
                copy[control.messageIdentifier] = control
                productLocales.append(ProductLocaleMessages(
                    productId: product,
                    locale: locale,
                    safeFallbackMessageId: safe.messageIdentifier,
                    controlMessageId: control.messageIdentifier
                ))
            }
        }
        // The safe-fallback and control messages are human-owned and were approved long ago.
        var states: [String: MessageState] = [:]
        for messages in productLocales {
            states[messages.safeFallbackMessageId] = .approved
            states[messages.controlMessageId] = .approved
        }
        for draft in report.passed {
            if let state = simulatedState(for: draft.messageIdentifier) { states[draft.messageIdentifier] = state }
            copy[draft.messageIdentifier] = draft.candidate
        }
        let compiled = try CatalogCompiler().compile(
            drafts: report.drafts,
            states: states,
            productLocales: productLocales,
            fallbackCopy: copy,
            primaryLocale: "en-US"
        )

        let assigner = configuration.experiment
        let now = epoch
        let maya = identifier(prefix: "200000100", landingIn: .treatment, assigner: assigner)
        let lea = identifier(prefix: "200000200", landingIn: .treatment, assigner: assigner)
        let jonas = identifier(prefix: "200000300", landingIn: .treatment, assigner: assigner)
        let kenji = identifier(prefix: "200000400", landingIn: .treatment, assigner: assigner)
        let priya = identifier(prefix: "200000500", landingIn: .holdout, assigner: assigner)

        let personas = [
            LabPersona(id: "maya", name: "Maya", summary: "2 years on Pro, never took an offer", originalTransactionId: maya, productId: proMonthly, locale: "en-US", inLocalStore: true),
            LabPersona(id: "lea", name: "Léa", summary: "In a free trial, device set to fr-CA", originalTransactionId: lea, productId: proMonthly, locale: "fr-CA", inLocalStore: true),
            LabPersona(id: "jonas", name: "Jonas", summary: "Yearly plan, redeemed an offer 10 days ago", originalTransactionId: jonas, productId: proYearly, locale: "de-DE", inLocalStore: true),
            LabPersona(id: "kenji", name: "Kenji", summary: "Card declined — in billing retry", originalTransactionId: kenji, productId: proMonthly, locale: "ja-JP", inLocalStore: true),
            LabPersona(id: "sam", name: "Sam", summary: "Not in this server's store — needs the remote lookup", originalTransactionId: "cold-sam", productId: proMonthly, locale: "en-US", inLocalStore: false),
            LabPersona(id: "priya", name: "Priya", summary: "Loyal, but in the 10% holdout", originalTransactionId: priya, productId: proMonthly, locale: "en-US", inLocalStore: true),
        ]

        var facts: [SubscriptionFact] = []
        func note(_ type: String, _ subtype: String? = nil, _ id: String, _ product: String, at date: Int64, purchase: Int64? = nil, offerType: Int? = nil, offer: String? = nil) {
            let summary = NotificationSummary(
                notificationType: type,
                subtype: subtype,
                notificationUUID: StableHash.contentUUID("lab:\(type):\(subtype ?? ""):\(id):\(date)"),
                signedDate: date,
                originalTransactionId: id,
                productId: product,
                purchaseDate: purchase,
                offerType: offerType,
                offerIdentifier: offer
            )
            if let fact = SubscriptionFact(summary) { facts.append(fact) }
        }
        note("SUBSCRIBED", "INITIAL_BUY", maya, proMonthly, at: now - 730 * day, purchase: now - 730 * day)
        note("DID_RENEW", nil, maya, proMonthly, at: now - 10 * day)
        note("SUBSCRIBED", "INITIAL_BUY", lea, proMonthly, at: now - 5 * day, purchase: now - 5 * day, offerType: 1)
        note("SUBSCRIBED", "INITIAL_BUY", jonas, proYearly, at: now - 200 * day, purchase: now - 200 * day)
        note("OFFER_REDEEMED", nil, jonas, proYearly, at: now - 10 * day, offerType: 2, offer: offerId(for: proYearly))
        note("SUBSCRIBED", "INITIAL_BUY", kenji, proMonthly, at: now - 400 * day, purchase: now - 400 * day)
        note("DID_FAIL_TO_RENEW", nil, kenji, proMonthly, at: now - 2 * day)
        note("SUBSCRIBED", "INITIAL_BUY", priya, proMonthly, at: now - 500 * day, purchase: now - 500 * day)

        return LabWorld(
            configuration: configuration,
            catalog: compiled.catalog,
            pipelineReport: report,
            compileResult: compiled,
            messageCopy: copy,
            personas: personas,
            seedFacts: facts
        )
    }

    /// What the remote source knows about a subscriber the local store has never seen.
    public static func coldFeatures(for originalTransactionId: String) -> SubscriberFeatures {
        var features = SubscriberFeatures(originalTransactionId: originalTransactionId)
        features.merge(SubscriptionFact(
            notificationUUID: StableHash.contentUUID("cold:" + originalTransactionId),
            signedDate: epoch - 400 * day,
            originalTransactionId: originalTransactionId,
            productId: proMonthly,
            kind: .subscribed(purchaseDate: epoch - 400 * day, inIntroOffer: false)
        ))
        return features
    }
}
