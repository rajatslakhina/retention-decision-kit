import Foundation
import RetentionEngine

public struct BriefFailure: Sendable {
    public let brief: CopyBrief
    public let error: any Error
}

public struct PipelineReport: Sendable {
    /// Every candidate drafted, with its gate verdict (and judge veto, if any), in brief order.
    public let drafts: [VariantDraft]
    public let failures: [BriefFailure]

    public var passed: [VariantDraft] { drafts.filter(\.isPublishable) }
    public var rejected: [VariantDraft] { drafts.filter { !$0.isPublishable } }

    /// How many variants each blocking rule rejected, for the dashboard. A variant counts once per
    /// rule, even when the rule fired in both header and body; one broken in several ways counts
    /// under each of those rules.
    public var rejectionsByRule: [String: Int] {
        drafts.reduce(into: [:]) { counts, draft in
            for rule in Set(draft.verdict.blockingRuleIds) { counts[rule, default: 0] += 1 }
        }
    }
}

/// The offline half of the system: draft → gate → (judge) → report.
///
/// It runs on a schedule or on demand, far from the request path. Drafting is concurrent but
/// bounded, so a large catalog does not open hundreds of simultaneous model calls. A brief that
/// fails (rate limit, malformed output) is reported and skipped; it never blocks the others.
public struct CopyPipeline: Sendable {
    public let drafter: any CopyDrafter
    public let gate: CopyEvalGate
    public let judge: (any CopyJudge)?
    public let maxConcurrentDrafts: Int

    public init(
        drafter: any CopyDrafter,
        gate: CopyEvalGate = .standard,
        judge: (any CopyJudge)? = nil,
        maxConcurrentDrafts: Int = 4
    ) {
        self.drafter = drafter
        self.gate = gate
        self.judge = judge
        self.maxConcurrentDrafts = min(max(maxConcurrentDrafts, 1), 64)
    }

    public func run(_ briefs: [CopyBrief]) async -> PipelineReport {
        let drafter = self.drafter
        let gate = self.gate
        let judge = self.judge
        var results: [(Int, Result<[VariantDraft], any Error>)] = []
        results.reserveCapacity(briefs.count)

        await withTaskGroup(of: (Int, Result<[VariantDraft], any Error>).self) { group in
            var nextIndex = 0
            func addNext() {
                guard nextIndex < briefs.count else { return }
                let index = nextIndex
                let brief = briefs[index]
                nextIndex += 1
                group.addTask {
                    do {
                        let candidates = try await drafter.draft(brief)
                        var drafts: [VariantDraft] = []
                        for candidate in candidates {
                            let verdict = gate.evaluate(candidate, brief: brief)
                            var veto: String?
                            if verdict.passed, let judge {
                                veto = try await judge.veto(candidate, brief: brief)
                            }
                            drafts.append(VariantDraft(brief: brief, candidate: candidate, verdict: verdict, judgeVeto: veto))
                        }
                        return (index, .success(drafts))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            for _ in 0..<maxConcurrentDrafts { addNext() }
            for await result in group {
                results.append(result)
                addNext()
            }
        }

        var drafts: [VariantDraft] = []
        var failures: [BriefFailure] = []
        for (index, result) in results.sorted(by: { $0.0 < $1.0 }) {
            switch result {
            case .success(let produced): drafts.append(contentsOf: produced)
            case .failure(let error): failures.append(BriefFailure(brief: briefs[index], error: error))
            }
        }
        return PipelineReport(drafts: drafts, failures: failures)
    }
}
