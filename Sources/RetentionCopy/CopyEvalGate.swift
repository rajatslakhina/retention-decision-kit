import Foundation
import RetentionEngine

public enum CopyField: String, Codable, Sendable, Hashable {
    case header, body
}

public struct CopyViolation: Codable, Sendable, Hashable {
    public enum Severity: String, Codable, Sendable, Hashable {
        /// The variant cannot be published.
        case block
        /// Published, but flagged for a human.
        case warn
    }

    public let ruleId: String
    public let field: CopyField
    public let severity: Severity
    public let detail: String

    public init(ruleId: String, field: CopyField, severity: Severity = .block, detail: String) {
        self.ruleId = ruleId
        self.field = field
        self.severity = severity
        self.detail = detail
    }
}

public struct CopyVerdict: Codable, Sendable, Hashable {
    public let violations: [CopyViolation]
    public var passed: Bool { !violations.contains { $0.severity == .block } }
    public var blockingRuleIds: [String] { violations.filter { $0.severity == .block }.map(\.ruleId) }

    public init(violations: [CopyViolation]) {
        self.violations = violations
    }
}

/// A deterministic check on one candidate.
public protocol CopyRule: Sendable {
    var id: String { get }
    func check(_ candidate: CopyCandidate, brief: CopyBrief) -> [CopyViolation]
}

/// The eval gate between the model and Apple.
///
/// The model's JSON schema asks for short, honest copy; the gate is what actually enforces it.
/// Rules are deterministic so a rejection is reproducible and explainable, and an LLM judge (if
/// configured) can only veto what passes here — never approve what fails.
public struct CopyEvalGate: Sendable {
    public let rules: [any CopyRule]

    public init(rules: [any CopyRule]) {
        self.rules = rules
    }

    public static let standard = CopyEvalGate(rules: [
        LengthRule(),
        EmptyTextRule(),
        DisallowedCharacterRule(),
        UnfilledTemplateRule(),
        PhraseRule.falseUrgency,
        PhraseRule.confirmshaming,
        PhraseRule.lossScare,
        PhraseRule.freeForever,
        PhraseRule.otherPlatforms,
        HardcodedPriceRule(),
        DiscountClaimRule(),
        GroundedNumberRule(),
        ScriptRule(),
        UntranslatedRule(),
    ])

    public func evaluate(_ candidate: CopyCandidate, brief: CopyBrief) -> CopyVerdict {
        CopyVerdict(violations: rules.flatMap { $0.check(candidate, brief: brief) })
    }
}

// MARK: - Rules

/// A decimal digit in any script ("5", "５", "٥") as its ASCII form, so a full-width "５０％" is
/// checked exactly like "50%".
func decimalDigit(_ character: Character) -> Character? {
    guard character.isNumber, let value = character.wholeNumberValue, (0...9).contains(value),
          character.unicodeScalars.count == 1,
          character.unicodeScalars.first?.properties.numericType == .decimal
    else { return nil }
    return Character(String(value))
}

/// Apple's Upload Message limits: header 66, body 144. Apple does not say which unit it counts,
/// so the gate counts UTF-16 code units — the largest of the common units for ordinary text.
/// A variant that fits here also fits if Apple counts scalars or grapheme clusters.
public struct LengthRule: CopyRule {
    public static let headerLimit = 66
    public static let bodyLimit = 144
    public let id = "length"
    public init() {}

    public func check(_ candidate: CopyCandidate, brief: CopyBrief) -> [CopyViolation] {
        var violations: [CopyViolation] = []
        let header = candidate.header.utf16.count
        let body = candidate.body.utf16.count
        if header > Self.headerLimit {
            violations.append(.init(ruleId: "length.header", field: .header, detail: "\(header) > \(Self.headerLimit) UTF-16 units"))
        }
        if body > Self.bodyLimit {
            violations.append(.init(ruleId: "length.body", field: .body, detail: "\(body) > \(Self.bodyLimit) UTF-16 units"))
        }
        return violations
    }
}

public struct EmptyTextRule: CopyRule {
    public let id = "text.empty"
    public init() {}

    public func check(_ candidate: CopyCandidate, brief: CopyBrief) -> [CopyViolation] {
        var violations: [CopyViolation] = []
        if candidate.header.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            violations.append(.init(ruleId: id, field: .header, detail: "header is empty"))
        }
        if candidate.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            violations.append(.init(ruleId: id, field: .body, detail: "body is empty"))
        }
        return violations
    }
}

/// Control characters, invisible format characters (bidi overrides, zero-width spaces), private-use
/// and replacement characters. Apple rejects "disallowed" characters without listing them; these
/// are the ones that are never legitimate in a cancellation sheet and are classic spoofing vectors.
public struct DisallowedCharacterRule: CopyRule {
    public let id = "text.disallowedCharacter"
    public init() {}

    public func check(_ candidate: CopyCandidate, brief: CopyBrief) -> [CopyViolation] {
        [(CopyField.header, candidate.header), (CopyField.body, candidate.body)].compactMap { field, text in
            guard let bad = text.unicodeScalars.first(where: Self.isDisallowed) else { return nil }
            let code = String(bad.value, radix: 16, uppercase: true)
            return .init(ruleId: id, field: field, detail: "U+\(code)")
        }
    }

    static func isDisallowed(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.value == 0x200D { return false }  // ZWJ: part of many emoji sequences
        switch scalar.properties.generalCategory {
        case .control, .format, .privateUse, .surrogate, .unassigned, .lineSeparator, .paragraphSeparator: return true
        default: return scalar.value == 0xFFFD
        }
    }
}

public struct UnfilledTemplateRule: CopyRule {
    public let id = "text.unfilledTemplate"
    private static let markers = ["{", "}", "[[", "]]", "<", ">", "%@", "TODO", "TBD", "lorem ipsum", "XXX"]
    public init() {}

    public func check(_ candidate: CopyCandidate, brief: CopyBrief) -> [CopyViolation] {
        [(CopyField.header, candidate.header), (CopyField.body, candidate.body)].compactMap { field, text in
            let lowered = text.lowercased()
            guard let marker = Self.markers.first(where: { lowered.contains($0.lowercased()) }) else { return nil }
            return .init(ruleId: id, field: field, detail: "contains \"\(marker)\"")
        }
    }
}

/// Phrase lists, matched case- and diacritic-insensitively.
public struct PhraseRule: CopyRule {
    public let id: String
    public let phrases: [String]
    public let reason: String

    public init(id: String, phrases: [String], reason: String) {
        self.id = id
        self.phrases = phrases.map(Self.fold)
        self.reason = reason
    }

    public func check(_ candidate: CopyCandidate, brief: CopyBrief) -> [CopyViolation] {
        [(CopyField.header, candidate.header), (CopyField.body, candidate.body)].compactMap { field, text in
            let folded = Self.fold(text)
            guard let phrase = phrases.first(where: { folded.contains($0) }) else { return nil }
            return .init(ruleId: id, field: field, detail: "\(reason): \"\(phrase)\"")
        }
    }

    /// Typography must not be a way around a phrase list: curly and modifier apostrophes become
    /// `'`; hyphens of every kind, and every space, line or paragraph separator (no-break, narrow,
    /// thin…), become one space, so "today-only" matches "today only"; runs of spaces collapse; and
    /// default-ignorable code points (ZWJ, variation selectors) are dropped — then case, diacritics
    /// and width are folded. Phrases are folded the same way.
    static func fold(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        var previousWasSpace = false
        for scalar in text.unicodeScalars {
            let mapped: Unicode.Scalar
            switch scalar.value {
            case 0x2018, 0x2019, 0x201B, 0x02BC, 0x2032, 0xFF07: mapped = "'"
            case 0x2D, 0x2010, 0x2011, 0x2012, 0x2013, 0x2212, 0xFE63, 0xFF0D: mapped = " "
            default:
                if scalar.properties.isDefaultIgnorableCodePoint { continue }
                switch scalar.properties.generalCategory {
                case .spaceSeparator, .lineSeparator, .paragraphSeparator: mapped = " "
                default: mapped = scalar == "\t" ? " " : scalar
                }
            }
            if mapped == " " {
                if previousWasSpace { continue }
                previousWasSpace = true
            } else {
                previousWasSpace = false
            }
            scalars.append(mapped)
        }
        return String(scalars).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    public static let falseUrgency = PhraseRule(
        id: "claims.falseUrgency",
        phrases: [
            "last chance", "act now", "only today", "today only", "ends tonight", "expires tonight", "hurry",
            "now or never", "final offer", "before it's too late",
            "letzte chance", "nur heute", "jetzt oder nie",
            "derniere chance", "aujourd'hui seulement", "seulement aujourd'hui", "depechez-vous",
            "ultima oportunidad", "solo hoy",
            "今だけ", "最後のチャンス", "本日限り", "お急ぎ",
        ],
        reason: "manufactured urgency"
    )

    public static let confirmshaming = PhraseRule(
        id: "claims.confirmshaming",
        phrases: [
            "you'll regret", "you will regret", "don't abandon", "giving up on", "are you sure you want to lose",
            "you're making a mistake", "bereuen", "vous allez regretter", "te arrepentiras", "後悔",
        ],
        reason: "guilt-based persuasion"
    )

    public static let lossScare = PhraseRule(
        id: "claims.lossScare",
        phrases: [
            "lose all your", "lose everything", "deleted forever", "gone forever", "erased forever",
            "alles verlieren", "tout perdre", "perderas todo", "すべて失",
        ],
        reason: "loss claim the cancellation flow does not cause"
    )

    public static let freeForever = PhraseRule(
        id: "claims.freeForever",
        phrases: ["free forever", "free for life", "für immer kostenlos", "gratuit pour toujours", "gratis para siempre", "永久無料"],
        reason: "misleading free claim"
    )

    public static let otherPlatforms = PhraseRule(
        id: "platform.otherPlatform",
        phrases: ["android", "google play", "play store", "on the web", "our website"],
        reason: "references another platform or purchase path"
    )
}

/// Apple shows offer prices localized per storefront. A hardcoded amount is wrong in every other
/// storefront and can contradict the price on the same sheet.
public struct HardcodedPriceRule: CopyRule {
    public let id = "claims.hardcodedPrice"
    private static let symbols: Set<Character> = ["$", "€", "£", "¥", "₹", "₩", "₽", "¢", "₺", "₫", "₱"]
    private static let codes: Set<String> = ["usd", "eur", "gbp", "jpy", "inr", "cad", "aud", "chf", "cny"]
    public init() {}

    public func check(_ candidate: CopyCandidate, brief: CopyBrief) -> [CopyViolation] {
        [(CopyField.header, candidate.header), (CopyField.body, candidate.body)].compactMap { field, text in
            if let symbol = text.first(where: { Self.symbols.contains($0) }) {
                return .init(ruleId: id, field: field, detail: "currency symbol \"\(symbol)\"")
            }
            let words = text.lowercased().split(whereSeparator: { !$0.isLetter })
            if let code = words.first(where: { Self.codes.contains(String($0)) }) {
                return .init(ruleId: id, field: field, detail: "currency code \"\(code.uppercased())\"")
            }
            return nil
        }
    }
}

/// A percentage claim must be backed by the offer the message is attached to.
public struct DiscountClaimRule: CopyRule {
    public let id = "claims.discount"
    public init() {}

    public func check(_ candidate: CopyCandidate, brief: CopyBrief) -> [CopyViolation] {
        [(CopyField.header, candidate.header), (CopyField.body, candidate.body)].flatMap { field, text in
            Self.percentages(in: text).compactMap { percent -> CopyViolation? in
                guard case .promotionalOffer = brief.kind else {
                    return .init(ruleId: "claims.discountWithoutOffer", field: field, detail: "\(percent)% but the message carries no offer")
                }
                guard percent == brief.offerDiscountPercent else {
                    let actual = brief.offerDiscountPercent.map { "\($0)%" } ?? "no stated discount"
                    return .init(ruleId: "claims.discountMismatch", field: field, detail: "says \(percent)%, offer is \(actual)")
                }
                return nil
            }
        }
    }

    /// Numbers immediately followed (optionally after a space) by a percent sign or word.
    static func percentages(in text: String) -> [Int] {
        let characters = Array(text)
        var result: [Int] = []
        var index = 0
        while index < characters.count {
            guard decimalDigit(characters[index]) != nil else {
                index += 1
                continue
            }
            var digits = ""
            while index < characters.count, let digit = decimalDigit(characters[index]) {
                digits.append(digit)
                index += 1
            }
            var lookahead = index
            while lookahead < characters.count, characters[lookahead] == " " || characters[lookahead] == "\u{00A0}" || characters[lookahead] == "\u{202F}" {
                lookahead += 1
            }
            let rest = String(characters[min(lookahead, characters.count)...]).lowercased()
            let isPercent = rest.hasPrefix("%") || rest.hasPrefix("％") || rest.hasPrefix("percent")
                || rest.hasPrefix("prozent") || rest.hasPrefix("pour cent") || rest.hasPrefix("por ciento")
            if isPercent, digits.count <= 3, let value = Int(digits) { result.append(value) }
        }
        return result
    }
}

/// Every number in the copy must come from the brief's value points (or be the offer's discount):
/// the model may not invent "10,000 recipes".
public struct GroundedNumberRule: CopyRule {
    public let id = "claims.ungroundedNumber"
    public init() {}

    public func check(_ candidate: CopyCandidate, brief: CopyBrief) -> [CopyViolation] {
        var allowed = Set(brief.valuePoints.flatMap(Self.numbers))
        if let percent = brief.offerDiscountPercent { allowed.insert(String(percent)) }
        return [(CopyField.header, candidate.header), (CopyField.body, candidate.body)].compactMap { field, text in
            guard let number = Self.numbers(in: text).first(where: { !allowed.contains($0) }) else { return nil }
            return .init(ruleId: id, field: field, detail: "\"\(number)\" is not in the brief's value points")
        }
    }

    /// Digit runs with grouping separators removed ("10,000" → "10000").
    static func numbers(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        let characters = Array(text)
        let separators: Set<Character> = [",", ".", " ", "\u{00A0}", "\u{202F}", "'", "，", "．"]
        for (index, character) in characters.enumerated() {
            if let digit = decimalDigit(character) {
                current.append(digit)
            } else if !current.isEmpty, separators.contains(character),
                      index + 1 < characters.count, decimalDigit(characters[index + 1]) != nil {
                continue
            } else if !current.isEmpty {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

/// Japanese, Chinese and Korean copy must actually contain that script.
public struct ScriptRule: CopyRule {
    public let id = "locale.scriptMismatch"
    public init() {}

    public func check(_ candidate: CopyCandidate, brief: CopyBrief) -> [CopyViolation] {
        let language = brief.locale.split(separator: "-").first.map(String.init) ?? ""
        let matches: (Unicode.Scalar) -> Bool
        switch language {
        case "ja": matches = { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) }
        case "zh": matches = { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
        case "ko": matches = { (0xAC00...0xD7AF).contains($0.value) || (0x1100...0x11FF).contains($0.value) }
        default: return []
        }
        guard !candidate.body.unicodeScalars.contains(where: matches) else { return [] }
        return [.init(ruleId: id, field: .body, detail: "no \(language) script in a \(brief.locale) message")]
    }
}

/// A heuristic, so it only warns: non-English copy that reads like English.
public struct UntranslatedRule: CopyRule {
    public let id = "locale.possiblyUntranslated"
    private static let stopwords: Set<String> = ["the", "your", "you", "and", "with", "keep", "stay", "for"]
    public init() {}

    public func check(_ candidate: CopyCandidate, brief: CopyBrief) -> [CopyViolation] {
        guard !brief.locale.hasPrefix("en") else { return [] }
        let words = candidate.body.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        let hits = words.filter { Self.stopwords.contains($0) }.count
        guard hits >= 2 else { return [] }
        return [.init(ruleId: id, field: .body, severity: .warn, detail: "\(hits) English stopwords in a \(brief.locale) message")]
    }
}
