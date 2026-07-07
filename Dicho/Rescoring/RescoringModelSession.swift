import Foundation
import FoundationModels

@Generable
struct CandidateIndex {
    @Guide(description: "The zero-based index of the chosen candidate")
    var index: Int
}

/// Thin seam over one `LanguageModelSession` used as a transcription-candidate
/// selector, so `RescoringService`'s gate/timeout/fallback logic is
/// unit-testable without live FoundationModels calls (fakes conform in
/// `DichoTests/Fakes/`).
///
/// Unlike the cleanup session, selector sessions are STATELESS by design:
/// `RescoringService` builds a fresh instance per ambiguous segment so
/// selections never influence each other and the context window never grows.
@MainActor
protocol RescoringModelSessioning: AnyObject, Sendable {
    /// Warms the underlying session to reduce first-selection latency.
    func prewarm()

    /// Runs one selection turn: given a prompt listing numbered candidates,
    /// returns the model's chosen index. Guided generation constrains the
    /// output to an integer — the model structurally cannot rewrite text.
    func respondCandidateIndex(to prompt: String) async throws -> Int
}

/// Production `RescoringModelSessioning` wrapping a single `LanguageModelSession`
/// with guided generation into `CandidateIndex`.
@MainActor
final class FoundationModelRescoringSession: RescoringModelSessioning {
    private let session: LanguageModelSession

    init(instructions: String) {
        // Same guardrails rationale as cleanup (M9): the candidates are
        // user-authored speech; default guardrails refuse profane-but-
        // legitimate content. Any residual guardrail error surfaces as a
        // thrown error, which RescoringService maps to top-hypothesis fallback.
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        session = LanguageModelSession(model: model, instructions: instructions)
    }

    func prewarm() {
        session.prewarm()
    }

    func respondCandidateIndex(to prompt: String) async throws -> Int {
        // Greedy sampling: selection is a deterministic decision (WWDC25 301).
        try await session.respond(
            to: prompt,
            generating: CandidateIndex.self,
            options: GenerationOptions(sampling: .greedy)
        ).content.index
    }
}
