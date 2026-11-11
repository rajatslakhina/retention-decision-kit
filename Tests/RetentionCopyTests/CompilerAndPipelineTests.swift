import RetentionEngine
import XCTest
@testable import RetentionCopy

final class CompilerAndPipelineTests: XCTestCase {
    func brief(_ segment: Segment = .loyal, kind: MessageKind = .text, locale: String = "en-US") -> CopyBrief {
        CopyBrief(productId: "pro", productName: "Notes Pro", locale: locale, segment: segment, kind: kind, offerDiscountPercent: nil, valuePoints: ["offline mode"])
    }

    func draft(_ header: String, _ body: String, brief: CopyBrief? = nil, passed: Bool = true) -> VariantDraft {
        let brief = brief ?? self.brief()
        let verdict = passed ? CopyVerdict(violations: []) : CopyVerdict(violations: [CopyViolation(ruleId: "x", field: .body, detail: "")])
        return VariantDraft(brief: brief, candidate: CopyCandidate(header: header, body: body), verdict: verdict)
    }

    let fallbacks = [ProductLocaleMessages(productId: "pro", locale: "en-US", safeFallbackMessageId: "safe", controlMessageId: "control")]
    /// Apple's view of the human-owned fallback messages: approved.
    let approvedFallbacks: [String: MessageState] = ["safe": .approved, "control": .approved]

    func states(_ extra: [String: MessageState] = [:]) -> [String: MessageState] {
        approvedFallbacks.merging(extra) { _, new in new }
    }

    func testContentAddressedIdentifiers() {
        let a = CopyCandidate(header: "H", body: "B")
        XCTAssertEqual(a.messageIdentifier, CopyCandidate(header: "H", body: "B", rationale: "different rationale").messageIdentifier)
        XCTAssertNotEqual(a.messageIdentifier, CopyCandidate(header: "H", body: "B.").messageIdentifier)
        XCTAssertNotEqual(a.messageIdentifier, CopyCandidate(header: "HB", body: "").messageIdentifier, "the separator keeps fields apart")
        XCTAssertNotNil(UUID(uuidString: a.messageIdentifier))
    }

    func testOnlyApprovedMessagesReachTheCatalog() throws {
        let approved = draft("Approved", "a")
        let pending = draft("Pending", "p")
        let unknown = draft("New", "n")
        let rejectedByReview = draft("Rejected", "r")
        let failedGate = draft("Bad", "b", passed: false)
        let known = states([
            approved.messageIdentifier: .approved,
            pending.messageIdentifier: .pending,
            rejectedByReview.messageIdentifier: .rejected,
        ])
        let result = try CatalogCompiler().compile(drafts: [approved, pending, unknown, rejectedByReview, failedGate], states: known, productLocales: fallbacks, primaryLocale: "en-US")
        let key = CatalogKey(productId: "pro", locale: "en-US", segment: .loyal)
        XCTAssertEqual(result.catalog.entries(for: key).map(\.messageIdentifier), [approved.messageIdentifier])
        XCTAssertEqual(result.uploads.map(\.messageIdentifier), [unknown.messageIdentifier], "only messages Apple has never seen are uploaded")
        XCTAssertEqual(Set(result.awaitingApproval.map(\.messageIdentifier)), [pending.messageIdentifier, unknown.messageIdentifier])
        XCTAssertEqual(result.dropped.count, 2)
    }

    func testRerunPlansNoDuplicateUploads() throws {
        let fresh = draft("Fresh", "copy")
        let first = try CatalogCompiler().compile(drafts: [fresh, fresh], states: states(), productLocales: fallbacks, primaryLocale: "en-US")
        XCTAssertEqual(first.uploads.count, 1)
        let second = try CatalogCompiler().compile(drafts: [fresh], states: states([fresh.messageIdentifier: .pending]), productLocales: fallbacks, primaryLocale: "en-US")
        XCTAssertTrue(second.uploads.isEmpty, "already uploaded under the same content-derived identifier")
    }

    func testSameMessageCanServeSeveralKinds() throws {
        let asText = draft("Same", "copy")
        let asOffer = draft("Same", "copy", brief: brief(kind: .promotionalOffer(offerId: "o")))
        let result = try CatalogCompiler().compile(drafts: [asText, asOffer], states: states([asText.messageIdentifier: .approved]), productLocales: fallbacks, primaryLocale: "en-US")
        let entries = result.catalog.entries(for: CatalogKey(productId: "pro", locale: "en-US", segment: .loyal))
        XCTAssertEqual(entries.map(\.kind), [.promotionalOffer(offerId: "o"), .text])
        XCTAssertEqual(Set(entries.map(\.messageIdentifier)).count, 1)
    }

    func testPerCellCapAndAppleLimit() throws {
        let drafts = (0..<8).map { draft("H\($0)", "B") }
        let approved = states(Dictionary(uniqueKeysWithValues: drafts.map { ($0.messageIdentifier, MessageState.approved) }))
        let result = try CatalogCompiler(perCellCap: 3).compile(drafts: drafts, states: approved, productLocales: fallbacks, primaryLocale: "en-US")
        XCTAssertEqual(result.catalog.entryCount, 3)
        XCTAssertEqual(result.dropped.filter { $0.reason.hasPrefix("below") }.count, 5)
        let existing = states(Dictionary(uniqueKeysWithValues: (0..<1_998).map { ("existing-\($0)", MessageState.approved) }))
        XCTAssertThrowsError(try CatalogCompiler().compile(drafts: [draft("one", "more")], states: existing, productLocales: fallbacks, primaryLocale: "en-US")) {
            guard case CompileError.appMessageLimitExceeded(let count)? = $0 as? CompileError else { return XCTFail("\($0)") }
            XCTAssertEqual(count, 2_001)
        }
    }

    func testMissingFallbackFailsCompilation() {
        let german = draft("Hallo", "Text", brief: brief(locale: "de-DE"))
        XCTAssertThrowsError(try CatalogCompiler().compile(drafts: [german], states: [german.messageIdentifier: .approved, "s": .approved, "c": .approved], productLocales: [ProductLocaleMessages(productId: "other", locale: "en-US", safeFallbackMessageId: "s", controlMessageId: "c")], primaryLocale: "en-US")) {
            XCTAssertEqual($0 as? CompileError, .catalog(.missingFallback(productId: "pro", locale: "de-DE")))
        }
    }

    /// The safe fallback must itself be displayable: Apple shows only APPROVED messages.
    func testFallbacksMustBeApproved() {
        let draft = draft("Approved", "a")
        let copy = ["safe": CopyCandidate(header: "Stay", body: "Thanks")]
        XCTAssertThrowsError(try CatalogCompiler().compile(drafts: [draft], states: [draft.messageIdentifier: .approved, "control": .approved, "safe": .pending], productLocales: fallbacks, fallbackCopy: copy, primaryLocale: "en-US")) {
            XCTAssertEqual($0 as? CompileError, .fallbacksNotApproved(messageIdentifiers: ["safe"], uploads: []))
        }
        XCTAssertThrowsError(try CatalogCompiler().compile(drafts: [draft], states: [draft.messageIdentifier: .approved], productLocales: fallbacks, fallbackCopy: copy, primaryLocale: "en-US")) {
            XCTAssertEqual($0 as? CompileError, .fallbacksNotApproved(
                messageIdentifiers: ["safe", "control"],
                uploads: [MessageUpload(messageIdentifier: "safe", header: "Stay", body: "Thanks")]
            ), "never-uploaded fallbacks are planned for upload when their copy is known")
        }
    }

    /// Ranking happens within a kind; the cell is always offer → switch plan → text, because text
    /// is always usable and anything ranked after it would never be reached.
    func testRankingNeverPutsTextAheadOfAnOffer() throws {
        let text = draft("Text wins", "a")
        let offer = draft("Offer", "b", brief: brief(kind: .promotionalOffer(offerId: "o")))
        let known = states([text.messageIdentifier: .approved, offer.messageIdentifier: .approved])
        let stats = [text.variantId: VariantStats(shown: 10_000, saved: 9_000), offer.variantId: VariantStats(shown: 10_000, saved: 10)]
        let result = try CatalogCompiler().compile(drafts: [text, offer], states: known, productLocales: fallbacks, stats: stats, primaryLocale: "en-US")
        XCTAssertEqual(result.catalog.entries(for: CatalogKey(productId: "pro", locale: "en-US", segment: .loyal)).map(\.kind), [.promotionalOffer(offerId: "o"), .text])
    }

    func testRankerPrefersLowerBoundAndKeepsExploring() {
        let ranker = VariantRanker(minimumImpressions: 100, explorationSlots: 1)
        let stats = [
            "lucky": VariantStats(shown: 120, saved: 60),   // 50%, wide interval
            "steady": VariantStats(shown: 5_000, saved: 2_300), // 46%, tight interval
            "new": VariantStats(shown: 3, saved: 3),
        ]
        XCTAssertEqual(ranker.rank(["lucky", "steady", "new", "fresh"], stats: stats, cap: 3), ["steady", "lucky", "new"])
        XCTAssertEqual(ranker.rank(["a", "a", "b"], stats: [:], cap: 5), ["a", "b"])
        XCTAssertEqual(ranker.rank(["a"], stats: [:], cap: 0), [])
        XCTAssertEqual(VariantStats(shown: 5, saved: 9).saved, 5)
    }

    func testPipelineBoundsConcurrencyAndIsolatesFailures() async {
        final class CountingDrafter: CopyDrafter, Sendable {
            let counters = Locked((current: 0, peak: 0))
            var peak: Int { counters.withLock { $0.peak } }
            struct Failure: Error {}
            func draft(_ brief: CopyBrief) async throws -> [CopyCandidate] {
                counters.withLock { state in
                    state.current += 1
                    state.peak = max(state.peak, state.current)
                }
                try? await Task.sleep(for: .milliseconds(5))
                counters.withLock { $0.current -= 1 }
                if brief.locale == "fr" { throw Failure() }
                return [CopyCandidate(header: "Before you go", body: "With Notes Pro you keep offline mode."), CopyCandidate(header: "Last chance", body: "Act now")]
            }
        }
        let drafter = CountingDrafter()
        let briefs = (0..<12).map { index in brief(locale: index == 5 ? "fr" : "en-US") }
        let report = await CopyPipeline(drafter: drafter, maxConcurrentDrafts: 3).run(briefs)
        XCTAssertLessThanOrEqual(drafter.peak, 3)
        XCTAssertGreaterThan(drafter.peak, 1, "drafting actually ran concurrently")
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(report.drafts.count, 22)
        XCTAssertEqual(report.passed.count, 11)
        XCTAssertEqual(report.drafts.flatMap(\.verdict.blockingRuleIds).filter { $0 == "claims.falseUrgency" }.count, 22, "fired in header and body")
        XCTAssertEqual(report.rejectionsByRule["claims.falseUrgency"], 11, "…but counted once per rejected variant")
    }

    func testJudgeCanVetoButNeverRescue() async {
        final class StrictJudge: CopyJudge, Sendable {
            let seen = Locked<[String]>([])
            func veto(_ candidate: CopyCandidate, brief: CopyBrief) async throws -> String? {
                seen.withLock { $0.append(candidate.header) }
                return candidate.header.contains("go") ? "tone" : nil
            }
        }
        struct Drafter: CopyDrafter {
            func draft(_ brief: CopyBrief) async throws -> [CopyCandidate] {
                [CopyCandidate(header: "Before you go", body: "With Notes Pro you keep offline mode."),
                 CopyCandidate(header: "Stay", body: "With Notes Pro you keep offline mode."),
                 CopyCandidate(header: "Act now", body: "x")]
            }
        }
        let judge = StrictJudge()
        let report = await CopyPipeline(drafter: Drafter(), judge: judge).run([brief()])
        XCTAssertEqual(report.passed.map(\.candidate.header), ["Stay"])
        XCTAssertEqual(report.drafts.first?.judgeVeto, "tone")
        XCTAssertEqual(judge.seen.withLock { $0 }.sorted(), ["Before you go", "Stay"], "the judge never sees gate failures")
    }

    func testDecodedStatsAndBriefsAreClamped() throws {
        let stats = try JSONDecoder().decode(VariantStats.self, from: Data(#"{"shown":10,"saved":50}"#.utf8))
        XCTAssertEqual(stats, VariantStats(shown: 10, saved: 10), "never more saves than impressions")
        let json = #"{"productId":"p","productName":"P","locale":"fr_fr","segment":"loyal","kind":{"text":{}},"offerDiscountPercent":500,"valuePoints":[],"variantCount":99}"#
        let decoded = try JSONDecoder().decode(CopyBrief.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.locale, "fr-FR")
        XCTAssertEqual(decoded.variantCount, 6)
        XCTAssertNil(decoded.offerDiscountPercent, "a discount on a text message is dropped, as the initializer does")
    }

    func testScriptedDrafterAppendsOneKnownBadVariant() async throws {
        let first = try await ScriptedCopyDrafter().draft(brief())
        let clean = try await ScriptedCopyDrafter(includeKnownBadVariants: false).draft(brief())
        XCTAssertEqual(first.count, clean.count + 1)
        XCTAssertTrue(clean.allSatisfy { CopyEvalGate.standard.evaluate($0, brief: brief()).passed }, "the scripted good copy passes")
        XCTAssertFalse(CopyEvalGate.standard.evaluate(try XCTUnwrap(first.last), brief: brief()).passed, "the appended known-bad variant fails")
    }
}
