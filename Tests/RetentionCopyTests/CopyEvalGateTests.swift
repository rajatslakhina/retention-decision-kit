import RetentionEngine
import XCTest
@testable import RetentionCopy

final class CopyEvalGateTests: XCTestCase {
    let gate = CopyEvalGate.standard

    func brief(locale: String = "en-US", kind: MessageKind = .text, percent: Int? = nil, points: [String] = ["unlimited projects"]) -> CopyBrief {
        CopyBrief(productId: "pro", productName: "Notes Pro", locale: locale, segment: .loyal, kind: kind, offerDiscountPercent: percent, valuePoints: points)
    }

    func blocking(_ header: String, _ body: String, brief: CopyBrief? = nil) -> [String] {
        gate.evaluate(CopyCandidate(header: header, body: body), brief: brief ?? self.brief()).blockingRuleIds
    }

    func testCleanCopyPasses() {
        XCTAssertEqual(blocking("Before you go", "With Notes Pro you keep unlimited projects."), [])
        let offer = brief(kind: .promotionalOffer(offerId: "o"), percent: 50, points: ["Offer: 3 months at 50% off"])
        XCTAssertEqual(blocking("Stay for 50% less", "Your next 3 months are 50% off if you stay.", brief: offer), [])
        XCTAssertEqual(blocking("続けるなら50%オフ", "次の3か月間が50%オフになります。", brief: brief(locale: "ja-JP", kind: .promotionalOffer(offerId: "o"), percent: 50, points: ["3"])), [])
    }

    func testLengthLimitsCountUTF16Units() {
        XCTAssertEqual(blocking(String(repeating: "a", count: 66), "ok"), [])
        XCTAssertEqual(blocking(String(repeating: "a", count: 67), "ok"), ["length.header"])
        XCTAssertEqual(blocking("ok", String(repeating: "b", count: 145)), ["length.body"])
        // 33 astral emoji = 33 graphemes but 66 UTF-16 units: the conservative count is what's limited.
        XCTAssertEqual(blocking(String(repeating: "🙂", count: 33), "ok"), [])
        XCTAssertEqual(blocking(String(repeating: "🙂", count: 34), "ok"), ["length.header"])
    }

    func testEmptyAndInvisibleCharacters() {
        XCTAssertEqual(blocking("  ", "body"), ["text.empty"])
        XCTAssertEqual(blocking("Stay\u{202E}", "body"), ["text.disallowedCharacter"], "bidi override")
        XCTAssertEqual(blocking("Stay", "line one\nline two"), ["text.disallowedCharacter"])
        XCTAssertEqual(blocking("Stay", "zero\u{200B}width"), ["text.disallowedCharacter"])
        XCTAssertEqual(blocking("Family 👨‍👩‍👧", "body"), [], "ZWJ inside an emoji sequence is fine")
    }

    func testTemplatesAndManipulation() {
        XCTAssertEqual(blocking("Hi {name}", "body"), ["text.unfilledTemplate"])
        XCTAssertEqual(blocking("Last chance!", "body"), ["claims.falseUrgency"])
        XCTAssertEqual(blocking("Letzte Chance", "Nur heute", brief: brief(locale: "de-DE")), ["claims.falseUrgency", "claims.falseUrgency"])
        XCTAssertEqual(blocking("Dernière chance", "ok", brief: brief(locale: "fr")), ["claims.falseUrgency"], "diacritic-insensitive")
        XCTAssertEqual(blocking("今だけ", "プロジェクト", brief: brief(locale: "ja-JP")), ["claims.falseUrgency"])
        XCTAssertEqual(blocking("Wait", "You'll regret leaving."), ["claims.confirmshaming"])
        XCTAssertEqual(blocking("Wait", "You will lose all your notes."), ["claims.lossScare"])
        XCTAssertEqual(blocking("Free forever", "ok"), ["claims.freeForever"])
        XCTAssertEqual(blocking("Stay", "Also on Android."), ["platform.otherPlatform"])
    }

    func testTypographyIsNotAWayAroundThePhraseRules() {
        XCTAssertEqual(blocking("Wait", "You\u{2019}ll regret leaving."), ["claims.confirmshaming"], "curly apostrophe")
        XCTAssertEqual(blocking("Wait", "Don\u{2019}t abandon us"), ["claims.confirmshaming"])
        XCTAssertEqual(blocking("Stay", "Before it\u{2019}s too late."), ["claims.falseUrgency"])
        XCTAssertEqual(blocking("Stay", "Before it\u{02BC}s too late."), ["claims.falseUrgency"], "modifier apostrophe")
        XCTAssertEqual(blocking("Aujourd\u{2019}hui seulement", "Restez avec nous.", brief: brief(locale: "fr")), ["claims.falseUrgency"], "French typography")
        XCTAssertEqual(blocking("D\u{E9}p\u{EA}chez\u{2011}vous", "Restez avec nous.", brief: brief(locale: "fr")), ["claims.falseUrgency"], "non-breaking hyphen")
        XCTAssertEqual(blocking("Last\u{00A0}chance", "ok"), ["claims.falseUrgency"], "no-break space")
        XCTAssertEqual(blocking("Last\u{202F}chance", "ok"), ["claims.falseUrgency"], "narrow no-break space")
        XCTAssertEqual(blocking("Last   chance", "ok"), ["claims.falseUrgency"], "a run of spaces")
        XCTAssertEqual(blocking("Last ch\u{200D}ance", "ok"), ["claims.falseUrgency"], "a joiner inside a word")
        XCTAssertEqual(blocking("Free\u{00A0}forever", "ok"), ["claims.freeForever"])
        XCTAssertEqual(blocking("Stay", "Also on Google\u{00A0}Play."), ["platform.otherPlatform"])
        XCTAssertEqual(blocking("Today-only offer", "ok"), ["claims.falseUrgency"], "hyphenated")
        XCTAssertEqual(blocking("Last-chance pricing", "ok"), ["claims.falseUrgency"])
        XCTAssertEqual(blocking("A now-or-never deal", "ok"), ["claims.falseUrgency"])
        XCTAssertEqual(blocking("D\u{E9}p\u{EA}chez vous", "Restez avec nous.", brief: brief(locale: "fr")), ["claims.falseUrgency"], "the hyphen is optional")
        XCTAssertEqual(Set(blocking("Act\u{2028}now", "ok")), ["text.disallowedCharacter", "claims.falseUrgency"], "a line separator is a newline")
    }

    func testPricesAndDiscounts() {
        XCTAssertEqual(Set(blocking("Stay for $4.99", "ok")), ["claims.hardcodedPrice", "claims.ungroundedNumber"])
        XCTAssertEqual(Set(blocking("Stay", "Only 4,99 €.")), ["claims.hardcodedPrice", "claims.ungroundedNumber"])
        XCTAssertTrue(blocking("Stay", "Just 5 USD.").contains("claims.hardcodedPrice"))
        XCTAssertTrue(blocking("Save 50%", "ok").contains("claims.discountWithoutOffer"))
        let offer = brief(kind: .promotionalOffer(offerId: "o"), percent: 50, points: [])
        XCTAssertTrue(blocking("Save 70%", "ok", brief: offer).contains("claims.discountMismatch"))
        XCTAssertTrue(blocking("Save 70 %", "ok", brief: offer).contains("claims.discountMismatch"), "space before %")
        XCTAssertTrue(blocking("７０％オフ", "プロジェクト", brief: brief(locale: "ja-JP", kind: .promotionalOffer(offerId: "o"), percent: 50, points: [])).contains("claims.discountMismatch"), "full-width digits")
        XCTAssertEqual(DiscountClaimRule.percentages(in: "50 % off, 20 percent, 7 days"), [50, 20])
    }

    func testNumbersMustBeGrounded() {
        XCTAssertEqual(blocking("Join 2 million fans", "ok"), ["claims.ungroundedNumber"])
        XCTAssertEqual(blocking("10,000 templates", "ok", brief: brief(points: ["10000 templates"])), [], "grouping separators are normalized")
        XCTAssertEqual(GroundedNumberRule.numbers(in: "1,000 and 3.5x and ٣"), ["1000", "35", "3"])
    }

    func testScriptAndTranslationChecks() {
        XCTAssertEqual(blocking("Hello", "Keep your projects.", brief: brief(locale: "ja-JP")), ["locale.scriptMismatch"])
        let verdict = gate.evaluate(CopyCandidate(header: "Avant", body: "Keep the projects and your notes."), brief: brief(locale: "fr"))
        XCTAssertTrue(verdict.passed, "possiblyUntranslated is a warning")
        XCTAssertEqual(verdict.violations.map(\.ruleId), ["locale.possiblyUntranslated"])
    }

    /// Every known mistake is caught by the rule meant to catch it — and only by that rule:
    /// remove the rule and the candidate passes the whole gate. So no rule is shadowed by another,
    /// and each one is load-bearing.
    func testEachKnownMistakeIsCaughtByExactlyItsOwnRule() {
        let offer = brief(kind: .promotionalOffer(offerId: "o"), percent: 50, points: ["Offer: 3 months at 50% off", "70"])
        let corpus: [(CopyCandidate, ruleFamily: String, ruleId: String)] = [
            (CopyCandidate(header: "Hurry", body: "ok"), "claims.falseUrgency", "claims.falseUrgency"),
            (CopyCandidate(header: "Stay for $", body: "ok"), "claims.hardcodedPrice", "claims.hardcodedPrice"),
            (CopyCandidate(header: "Save 70%", body: "ok"), "claims.discount", "claims.discountMismatch"),
            (CopyCandidate(header: "Join 9 fans", body: "ok"), "claims.ungroundedNumber", "claims.ungroundedNumber"),
            (CopyCandidate(header: "ok", body: String(repeating: "word ", count: 40)), "length", "length.body"),
            (CopyCandidate(header: "Wait", body: "you'll regret it"), "claims.confirmshaming", "claims.confirmshaming"),
            (CopyCandidate(header: "Wait", body: "Stay\u{202E}"), "text.disallowedCharacter", "text.disallowedCharacter"),
            (CopyCandidate(header: "Hi {name}", body: "ok"), "text.unfilledTemplate", "text.unfilledTemplate"),
        ]
        for (candidate, family, ruleId) in corpus {
            let verdict = gate.evaluate(candidate, brief: offer)
            XCTAssertEqual(verdict.blockingRuleIds, [ruleId], "\(candidate.header): exactly one rule fires")
            let without = CopyEvalGate(rules: gate.rules.filter { $0.id != family })
            XCTAssertTrue(without.evaluate(candidate, brief: offer).passed, "\(ruleId): nothing else would have caught it")
        }
        for candidate in ScriptedCopyDrafter.knownBadVariants(for: offer) {
            XCTAssertFalse(gate.evaluate(candidate, brief: offer).passed, candidate.header)
        }
    }
}
