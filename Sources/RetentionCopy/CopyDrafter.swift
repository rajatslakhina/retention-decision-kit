import Foundation
import RetentionEngine

/// Drafts candidate copy for a brief. In production, a model; in tests and the demo, a script.
public protocol CopyDrafter: Sendable {
    func draft(_ brief: CopyBrief) async throws -> [CopyCandidate]
}

/// An optional second opinion (for example an LLM judge). It runs only on candidates the
/// deterministic gate already passed, and it can only veto — it can never rescue a gate failure.
public protocol CopyJudge: Sendable {
    /// `nil` to accept, or a reason to veto.
    func veto(_ candidate: CopyCandidate, brief: CopyBrief) async throws -> String?
}

/// A deterministic drafter for tests and the offline demo: no network, no API key.
///
/// For each brief it returns good candidates written from the brief's value points plus, when
/// `includeKnownBadVariants` is on, the mistakes a real model makes — manufactured urgency, a
/// hardcoded price, the wrong discount, an invented statistic, an over-long body — so the gate
/// has something real to reject.
public struct ScriptedCopyDrafter: CopyDrafter {
    /// The mistakes a real model makes, each of which the standard gate must reject.
    public static func knownBadVariants(for brief: CopyBrief) -> [CopyCandidate] {
        let percent = brief.offerDiscountPercent ?? 30
        return [
            CopyCandidate(header: "Last chance!", body: "This offer ends tonight. Act now or lose all your progress.", rationale: "urgency + loss scare"),
            CopyCandidate(header: "Stay for $4.99", body: "Keep \(brief.productName) for just $4.99 a month.", rationale: "hardcoded price"),
            CopyCandidate(header: "Save \(percent + 20)% today", body: "Stay and get \(percent + 20)% off your next months.", rationale: "wrong discount"),
            CopyCandidate(header: "Join 2 million fans", body: "Over 2 million people use \(brief.productName) every day.", rationale: "invented statistic"),
            CopyCandidate(
                header: "We built this for you",
                body: String(repeating: "Every feature in \(brief.productName) was designed with you in mind. ", count: 3),
                rationale: "too long"
            ),
        ]
    }

    public let includeKnownBadVariants: Bool

    public init(includeKnownBadVariants: Bool = true) {
        self.includeKnownBadVariants = includeKnownBadVariants
    }

    public func draft(_ brief: CopyBrief) async throws -> [CopyCandidate] {
        let language = brief.locale.split(separator: "-").first.map(String.init) ?? "en"
        let good: [CopyCandidate]
        switch language {
        case "fr": good = Self.french(brief)
        case "de": good = Self.german(brief)
        case "ja": good = Self.japanese(brief)
        default: good = Self.english(brief)
        }
        let drafted = Array(good.prefix(brief.variantCount))
        guard includeKnownBadVariants else { return drafted }
        // One known-bad variant per brief, rotating through the catalogue of real model mistakes.
        let bad = Self.knownBadVariants(for: brief)
        let pick = Int(StableHash.fnv1a64("\(brief.productId)|\(brief.locale)|\(brief.segment.rawValue)|\(brief.kind.canonical)") % UInt64(bad.count))
        return drafted + [bad[pick]]
    }

    // MARK: Scripted copy, written from the brief's value points only.

    private static func english(_ brief: CopyBrief) -> [CopyCandidate] {
        let point = brief.valuePoints.first ?? brief.productName
        let percent = brief.offerDiscountPercent ?? 0
        switch (brief.segment, brief.kind) {
        case (.billingRetry, _):
            return [CopyCandidate(header: "Update your payment method", body: "Update your payment details to keep using \(brief.productName) without interruption.", rationale: "billing recovery")]
        case (.trial, _):
            return [CopyCandidate(header: "Your trial isn't over yet", body: "You still have time to try \(point) in \(brief.productName).", rationale: "trial framing")]
        case (_, .promotionalOffer):
            return [
                CopyCandidate(header: "Stay for \(percent)% less", body: "Keep \(point). Your next 3 months are \(percent)% off if you stay.", rationale: "offer, exact discount"),
                CopyCandidate(header: "A thank-you for staying", body: "You've been with \(brief.productName) a while. Here's \(percent)% off to keep going.", rationale: "loyalty"),
            ]
        case (_, .switchPlan):
            return [CopyCandidate(header: "Keep the essentials for less", body: "Switch to Notes Lite and keep your notes in sync.", rationale: "downgrade instead of churn")]
        default:
            return [
                CopyCandidate(header: "Before you go", body: "With \(brief.productName) you keep \(point).", rationale: "value reminder"),
                CopyCandidate(header: "Your work stays yours", body: "Everything you made in \(brief.productName) stays available.", rationale: "reassurance"),
            ]
        }
    }

    private static func french(_ brief: CopyBrief) -> [CopyCandidate] {
        let point = brief.valuePoints.first ?? brief.productName
        let percent = brief.offerDiscountPercent ?? 0
        switch (brief.segment, brief.kind) {
        case (.billingRetry, _):
            return [CopyCandidate(header: "Mettez à jour votre paiement", body: "Actualisez votre moyen de paiement pour continuer avec \(brief.productName).", rationale: "billing recovery")]
        case (.trial, _):
            return [CopyCandidate(header: "Votre essai continue", body: "Il vous reste du temps pour découvrir les \(point) de \(brief.productName).", rationale: "trial framing")]
        case (_, .promotionalOffer):
            return [CopyCandidate(header: "Restez, avec \(percent) % de remise", body: "Gardez vos \(point) : vos 3 prochains mois sont à -\(percent) %.", rationale: "offer, exact discount")]
        case (_, .switchPlan):
            return [CopyCandidate(header: "L'essentiel, pour moins cher", body: "Passez à Notes Lite et gardez vos notes synchronisées.", rationale: "downgrade")]
        default:
            return [CopyCandidate(header: "Avant de partir", body: "Avec \(brief.productName), vous gardez vos \(point).", rationale: "value reminder")]
        }
    }

    private static func german(_ brief: CopyBrief) -> [CopyCandidate] {
        let point = brief.valuePoints.first ?? brief.productName
        let percent = brief.offerDiscountPercent ?? 0
        switch (brief.segment, brief.kind) {
        case (.billingRetry, _):
            return [CopyCandidate(header: "Zahlung aktualisieren", body: "Aktualisiere deine Zahlungsmethode, um \(brief.productName) weiter zu nutzen.", rationale: "billing recovery")]
        case (.trial, _):
            return [CopyCandidate(header: "Deine Testphase läuft noch", body: "Du hast noch Zeit, \(point) in \(brief.productName) auszuprobieren.", rationale: "trial framing")]
        case (_, .promotionalOffer):
            return [CopyCandidate(header: "Bleib und spar \(percent) %", body: "Behalte \(point): Deine nächsten 3 Monate kosten \(percent) % weniger.", rationale: "offer, exact discount")]
        case (_, .switchPlan):
            return [CopyCandidate(header: "Das Wichtigste, günstiger", body: "Wechsle zu Notes Lite und behalte deine synchronisierten Notizen.", rationale: "downgrade")]
        default:
            return [CopyCandidate(header: "Bevor du gehst", body: "Mit \(brief.productName) behältst du \(point).", rationale: "value reminder")]
        }
    }

    private static func japanese(_ brief: CopyBrief) -> [CopyCandidate] {
        let point = brief.valuePoints.first ?? brief.productName
        let percent = brief.offerDiscountPercent ?? 0
        switch (brief.segment, brief.kind) {
        case (.billingRetry, _):
            return [CopyCandidate(header: "お支払い情報の更新", body: "お支払い方法を更新すると、\(brief.productName)を引き続きご利用いただけます。", rationale: "billing recovery")]
        case (.trial, _):
            return [CopyCandidate(header: "無料体験はまだ続きます", body: "\(brief.productName)の「\(point)」をもう少しお試しください。", rationale: "trial framing")]
        case (_, .promotionalOffer):
            return [CopyCandidate(header: "続けるなら\(percent)%オフ", body: "「\(point)」はそのまま。次の3か月間が\(percent)%オフになります。", rationale: "offer, exact discount")]
        case (_, .switchPlan):
            return [CopyCandidate(header: "必要な機能をもっと手頃に", body: "Notes Liteに切り替えて、メモの同期を続けましょう。", rationale: "downgrade")]
        default:
            return [CopyCandidate(header: "解約の前に", body: "\(brief.productName)では「\(point)」をご利用いただけます。", rationale: "value reminder")]
        }
    }
}
