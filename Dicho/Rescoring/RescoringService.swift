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
        // Per-segment context is precomputed from preceding TOP hypotheses —
        // not from earlier chosen candidates — so selections are independent
        // and can run concurrently. Selections rarely change words, so the
        // context difference is negligible; the latency win is not (round-2
        // field test: 12 serial selections dominated stop-to-insert time).
        var contexts: [String] = []
        var precedingText: [String] = []
        for segment in segments {
            contexts.append(precedingText.joined(separator: " "))
            let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { precedingText.append(trimmed) }
        }

        // Default every segment to its top hypothesis; overwrite with the
        // model's choice for gate-flagged segments as selections complete.
        var chosen = segments.map(\.text)
        let modelAvailable = isModelAvailable()
        await withTaskGroup(of: (Int, String).self) { group in
            for (index, segment) in segments.enumerated()
            where modelAvailable && RescoringGate.needsRescoring(segment, threshold: threshold) {
#if DEBUG
                print("[DEBUG] RescoringService: gate FIRED for '\(segment.text)' (confidence=\(segment.confidence.map { String(format: "%.2f", $0) } ?? "nil"), \(segment.alternatives.count) candidates)")
#endif
                let session = takeSession()
                let context = contexts[index]
                group.addTask { [segmentTimeout] in
                    (index, await Self.select(segment, session: session, context: context, timeout: segmentTimeout))
                }
            }
            for await (index, text) in group {
                chosen[index] = text
            }
        }

        // Same trim-and-join rule the coordinator applied in M9: segments
        // arrive with leading spaces; whitespace-only segments add nothing.
        return chosen
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
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
        speaker most plausibly said. Candidate 0 is the recognizer's most \
        likely transcription: choose a different candidate ONLY when it \
        clearly fits the context better, for example when candidate 0 is \
        ungrammatical or nonsensical there. Never switch because another \
        candidate sounds more formal or polished — spoken forms like "gonna" \
        and "gotta" must stay exactly as spoken. If unsure, answer 0. Respond \
        with the chosen candidate's index only. Never invent text that is not \
        among the candidates.
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

    /// Runs one selection: prompt → index (raced against `timeout`) →
    /// candidate, with the snap rule; falls back to the top hypothesis on any
    /// failure. Static + parameter-passing so concurrent task-group children
    /// share no mutable service state.
    private static func select(
        _ segment: TranscriptUpdate,
        session: any RescoringModelSessioning,
        context: String,
        timeout: TimeInterval
    ) async -> String {
        let prompt = Self.buildPrompt(
            candidates: segment.alternatives,
            context: String(context.suffix(Self.contextWindowMaxChars))
        )

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
#if DEBUG
                print("[DEBUG] RescoringService: selector index \(index) out of range → top hypothesis kept")
#endif
                return segment.text
            }
            guard index != 0 else {
#if DEBUG
                print("[DEBUG] RescoringService: selector kept the top hypothesis (index 0)")
#endif
                return segment.text
            }
            let chosen = segment.alternatives[index]
            // Snap rule (field test 2026-07-07): a choice that differs from the
            // top hypothesis only in punctuation or casing is churn, not repair
            // — the transcriber's own punctuation is the better signal.
            guard !RescoringGate.lexicallyEquivalent(chosen, segment.text) else {
#if DEBUG
                print("[DEBUG] RescoringService: selector chose punctuation-only variant → top hypothesis kept")
#endif
                return segment.text
            }
#if DEBUG
            print("[DEBUG] RescoringService: selector chose index \(index): '\(chosen)'")
#endif
            return chosen
        } catch {
            // Timeout, guardrail, or any model error: the top hypothesis is
            // always an acceptable answer — rescoring is best-effort.
#if DEBUG
            print("[DEBUG] RescoringService: selection failed (timeout/error) → top hypothesis kept")
#endif
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
