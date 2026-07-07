import Foundation
import FoundationModels

/// Production rescoring service: deterministic gate + stateless model selector.
///
/// For each finalized segment, `RescoringGate` decides pass-through vs
/// rescore; only genuinely ambiguous segments (low confidence AND lexically
/// distinct alternatives) reach the model. Each selection runs on a FRESH
/// session — selections never share context, so earlier choices cannot bias
/// later ones and the window never overflows. The selector chooses by INDEX
/// via guided generation, so it structurally cannot rewrite or hallucinate
/// text; any error, timeout, or out-of-range index falls back to the
/// transcriber's top hypothesis. `rescore` therefore never throws.
@MainActor
final class RescoringService: RescoringServicing {

    private let segmentTimeout: TimeInterval
    private let threshold: Double
    private let isModelAvailable: @MainActor () -> Bool
    private let makeSessionImpl: @MainActor (String) -> any RescoringModelSessioning

    private var pendingSession: (any RescoringModelSessioning)?

    /// Trailing window of already-assembled transcript given to the selector
    /// as context. Kept short: the segment's immediate neighborhood is what
    /// disambiguates ("worked at the local ___"), and short prompts keep
    /// per-segment latency inside the timeout budget.
    private static let contextWindowMaxChars = 160

    /// - Parameters:
    ///   - segmentTimeout: per-segment selection timeout; on expiry the
    ///     segment keeps the top hypothesis. Defaults to
    ///     `Constants.rescoringSegmentTimeout` (resolved in the body — the
    ///     default-argument position is nonisolated).
    ///   - threshold: confidence gate threshold, defaulting to
    ///     `Constants.rescoringConfidenceThreshold`.
    ///   - isModelAvailable: injectable availability check.
    ///   - makeSession: factory building a selector session from instructions.
    init(
        segmentTimeout: TimeInterval? = nil,
        threshold: Double? = nil,
        isModelAvailable: @escaping @MainActor () -> Bool = {
            if case .available = SystemLanguageModel.default.availability { true } else { false }
        },
        makeSession: @escaping @MainActor (String) -> any RescoringModelSessioning = {
            FoundationModelRescoringSession(instructions: $0)
        }
    ) {
        self.segmentTimeout = segmentTimeout ?? Constants.rescoringSegmentTimeout
        self.threshold = threshold ?? Constants.rescoringConfidenceThreshold
        self.isModelAvailable = isModelAvailable
        self.makeSessionImpl = makeSession
    }

    // MARK: - RescoringServicing

    func prewarm() {
        guard isModelAvailable() else { return }
        let session = makeSessionImpl(Self.buildInstructions())
        session.prewarm()
        pendingSession = session
    }

    func rescore(_ segments: [TranscriptUpdate]) async -> String {
        var assembled: [String] = []
        for segment in segments {
            let chosen = await chooseText(for: segment, context: assembled.joined(separator: " "))
            // Same trim-and-join rule the coordinator applied in M9: segments
            // arrive with leading spaces; whitespace-only segments add nothing.
            let trimmed = chosen.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { assembled.append(trimmed) }
        }
        return assembled.joined(separator: " ")
    }

    // MARK: - Internal — exposed for golden-file tests

    /// System instructions for the selector session.
    static func buildInstructions() -> String {
        """
        You select the correct transcription of one spoken segment. You are \
        given the text spoken so far and a numbered list of candidate \
        transcriptions of the SAME audio segment. Speech recognition sometimes \
        writes a similar-sounding word in place of what the speaker said; pick \
        the candidate that best fits the surrounding context — the words the \
        speaker most plausibly said. Respond with the chosen candidate's index \
        only. Never invent text that is not among the candidates.
        """
    }

    /// Per-segment selection prompt: preceding context + numbered candidates.
    static func buildPrompt(candidates: [String], context: String) -> String {
        let numbered = candidates.enumerated()
            .map { "\($0.offset). \($0.element)" }
            .joined(separator: "\n")
        return """
        Text so far: \(context)
        Candidate transcriptions of the next segment:
        \(numbered)
        Choose the index of the correct candidate.
        """
    }

    // MARK: - Private

    /// Chooses the text for one segment: gate → fresh session → index →
    /// candidate; falls back to the top hypothesis on any failure.
    private func chooseText(for segment: TranscriptUpdate, context: String) async -> String {
        guard isModelAvailable(),
              RescoringGate.needsRescoring(segment, threshold: threshold) else {
            return segment.text
        }

        let session = takeSession()
        let prompt = Self.buildPrompt(
            candidates: segment.alternatives,
            context: String(context.suffix(Self.contextWindowMaxChars))
        )
        let timeout = segmentTimeout

        do {
            let index = try await withThrowingTaskGroup(of: Int.self) { group in
                group.addTask { try await session.respondCandidateIndex(to: prompt) }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    throw CancellationError()
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
            guard segment.alternatives.indices.contains(index) else {
                return segment.text
            }
            return segment.alternatives[index]
        } catch {
            // Timeout, guardrail, or any model error: the top hypothesis is
            // always an acceptable answer — rescoring is best-effort.
            return segment.text
        }
    }

    /// Consumes the prewarmed session if one is waiting; otherwise builds a
    /// fresh one. Sessions are never reused across segments (stateless).
    private func takeSession() -> any RescoringModelSessioning {
        if let pending = pendingSession {
            pendingSession = nil
            return pending
        }
        return makeSessionImpl(Self.buildInstructions())
    }
}
