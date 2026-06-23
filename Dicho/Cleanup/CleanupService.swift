import Foundation
import FoundationModels

@Generable
struct CleanedText {
    @Guide(description: "The cleaned text with filler words removed and self-corrections applied")
    var text: String
}

/// Production cleanup service using Foundation Models guided generation.
///
/// One `LanguageModelSession` is created per dictation and prewarmed when recording
/// starts. Long transcripts are split into ≤512-token chunks and cleaned serially,
/// then joined. The coordinator's `withCleanupTimeout` provides the per-chunk timeout;
/// this class is responsible only for the model interaction.
@MainActor
final class CleanupService: CleanupServicing {

    private var pendingSession: LanguageModelSession?

    // MARK: - CleanupServicing

    func prewarm() {
        guard case .available = SystemLanguageModel.default.availability else { return }
        let session = makeSession()
        session.prewarm()
        pendingSession = session
    }

    func clean(_ text: String, appContext: AppContext?) async throws -> String {
        guard case .available = SystemLanguageModel.default.availability else {
            throw CleanupError.unavailable
        }

        // Short-input bypass: very short inputs (single tokens / abbreviations)
        // are where the on-device model is most likely to hallucinate or echo
        // its own system prompt, and cleanup barely helps anyway.
        if Self.shouldBypassCleanup(for: text) {
            return text
        }

        let chunks = Self.splitIntoChunks(text)
        var cleaned: [String] = []
        // Prewarm built a baseline (no-hint) session; if the appContext implies a
        // hint, the prewarmed instructions are stale and we discard it.
        let needsContextAwareSession = Self.hint(for: appContext?.category ?? .generalWriting) != nil

        for (index, chunk) in chunks.enumerated() {
            let session: LanguageModelSession
            if index == 0 {
                if needsContextAwareSession {
                    session = makeSession(appContext: appContext)
                    pendingSession = nil
                } else if let pending = pendingSession {
                    session = pending
                    pendingSession = nil
                } else {
                    session = makeSession()
                }
            } else {
                session = makeSession(appContext: appContext)
            }
            let response = try await session.respond(
                to: Self.buildPrompt(for: chunk),
                generating: CleanedText.self
            )
            let cleanedChunk = response.content.text
            // Defensive: if the model echoed its guided-generation schema or
            // any other system-prompt artifact, fall back to the raw chunk
            // rather than insert garbage into the user's document.
            cleaned.append(Self.isLikelyModelLeakage(cleanedChunk) ? chunk : cleanedChunk)
        }

        return cleaned.joined(separator: " ")
    }

    // MARK: - Internal — exposed for golden-file tests

    /// System instructions baked into every session. When `appContext` is non-nil
    /// and its category has a hint (i.e. anything other than `.generalWriting`),
    /// the hint is appended AFTER the forbidden-actions block so it cannot
    /// override the core contract.
    /// Tested via `CleanupServiceTests` without live model calls.
    static func buildInstructions(for appContext: AppContext? = nil) -> String {
        let base = """
        You are a dictation-cleanup assistant. Clean the transcript by:
        - Removing filler words (um, uh, like when used as a filler, you know, etc.)
        - Applying explicit self-corrections: if the speaker says \
        "Tuesday — no wait, Friday", output "Friday"
        - Adding light punctuation (commas, periods) and standard capitalization

        FORBIDDEN: Do NOT paraphrase, summarize, translate, change register or tone, \
        or alter any identifiers, numbers, URLs, code, or technical terms. \
        Output ONLY the cleaned text with no commentary, preamble, or explanation.
        """
        guard let hint = appContext.flatMap({ Self.hint(for: $0.category) }) else {
            return base
        }
        return base + "\n\n" + hint
    }

    /// One-sentence target-app hint appended to the instructions. Returns `nil`
    /// for `.generalWriting` so the prompt remains identical to the no-context
    /// baseline when the frontmost app doesn't match any known category.
    static func hint(for category: AppCategory) -> String? {
        switch category {
        case .ide:
            return "The user is dictating into a code editor. Preserve any token "
                + "that looks like an identifier (camelCase, snake_case, dotted, or "
                + "punctuated), URL, file path, or number exactly as transcribed. "
                + "Treat ALL-CAPS acronyms (JSON, URL, HTTP, API, UUID, SQL, HTML, CSS, "
                + "XML, REST, JWT, IDE, etc.) as identifiers — never replace them with "
                + "homophones (e.g. JSON must never become \"Jason\"). Do NOT split a "
                + "compound identifier into separate English words."
        case .terminal:
            return "The user is dictating into a terminal. Preserve commands, "
                + "flags, paths, and shell punctuation exactly as transcribed, including "
                + "the original spacing between tokens. Do NOT add commas, periods, or "
                + "other punctuation between consecutive command tokens, arguments, or "
                + "flags — terminal input has no English sentence structure."
        case .messaging:
            return "The user is dictating an informal message; light contractions "
                + "are acceptable but do not change register or formality."
        case .email:
            return "The user is dictating an email body; standard sentence "
                + "structure and capitalization are appropriate."
        case .browser:
            return "The user is dictating into a browser text area; apply default cleanup."
        case .notes:
            return "The user is dictating notes; brief, fragmentary phrasing is acceptable."
        case .scriptWriting:
            return "The user is dictating into a screenwriting app. Preserve "
                + "*formatting tokens* exactly as transcribed: scene headings "
                + "(INT./EXT.), character names (often ALL CAPS), parentheticals, "
                + "transitions (CUT TO:, FADE OUT.), and other standard "
                + "screenplay/Fountain markers. Dialogue and scene description "
                + "are ordinary prose — still apply the same filler removal, "
                + "self-correction, and light punctuation rules from the base "
                + "instructions to those passages."
        case .filmEditing:
            return "The user is dictating into a video/film editing app; preserve "
                + "clip names, timecodes (HH:MM:SS:FF), keyboard shortcuts, and "
                + "numeric markers exactly as transcribed."
        case .generalWriting:
            return nil
        }
    }

    /// Wraps a transcript chunk in the per-request prompt.
    static func buildPrompt(for text: String) -> String {
        "Clean this dictation transcript:\n\(text)"
    }

    /// Returns `true` when the input is too short to be worth invoking the model
    /// on, in which case `clean(_:appContext:)` will pass it through unchanged.
    /// Threshold: fewer than `Constants.cleanupMinWordsForCleanup` words after
    /// trimming surrounding whitespace.
    ///
    /// Rationale: on-device Foundation Models occasionally produces hallucinated
    /// schema-leakage output for single-token inputs (see `isLikelyModelLeakage`),
    /// and the cleanup payoff for one-word inputs is negligible.
    static func shouldBypassCleanup(for text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let wordCount = trimmed.split(whereSeparator: { $0.isWhitespace }).count
        return wordCount < Constants.cleanupMinWordsForCleanup
    }

    /// Returns `true` when `text` looks like the on-device Foundation Models
    /// model echoed its guided-generation system prompt instead of producing
    /// a clean response. The cleanup pipeline falls back to the raw chunk when
    /// this detector fires, so corrupted output never reaches the user's document.
    ///
    /// Observed M7 manual-test leakage (2026-06-23):
    ///   Input "INT" → output  `"INT.\nresponse format in json. name: CleanedText schema: {"`
    ///
    /// Detection is intentionally narrow: case-insensitive substring checks
    /// against patterns that are vanishingly unlikely in legitimate dictation
    /// (`"response format"`, `"schema:"`, `"name: CleanedText"`, `@Generable`,
    /// `@Guide`). A genuine sentence about "JSON schemas" or about a person
    /// named "CleanedText" would survive without false positives.
    static func isLikelyModelLeakage(_ text: String) -> Bool {
        let leakageMarkers = [
            "response format",
            "schema:",
            "name: CleanedText",
            "@Generable",
            "@Guide",
        ]
        return leakageMarkers.contains { text.localizedCaseInsensitiveContains($0) }
    }

    /// Splits `text` into chunks that each fit within the token budget.
    /// Uses ~4 chars per token as the approximation.
    /// Splits at sentence boundaries (`.`, `!`, `?`) when possible,
    /// falling back to word boundaries, then a hard character cut.
    static func splitIntoChunks(_ text: String) -> [String] {
        let charBudget = Constants.cleanupChunkTokenBudget * 4
        guard text.count > charBudget else { return [text] }

        var chunks: [String] = []
        var remaining = text

        while remaining.count > charBudget {
            let budgetIndex = remaining.index(remaining.startIndex, offsetBy: charBudget)
            // `prefix` is a Substring — its indices are valid in `remaining`.
            let prefix = remaining[remaining.startIndex..<budgetIndex]

            // Prefer splitting after the last sentence-ending punctuation.
            var splitPoint: String.Index? = nil
            for idx in prefix.indices.reversed() {
                if ".!?".contains(prefix[idx]) {
                    splitPoint = prefix.index(after: idx)
                    break
                }
            }

            // Fall back to last word boundary.
            if splitPoint == nil {
                splitPoint = prefix.lastIndex(of: " ").map { prefix.index(after: $0) }
            }

            // Hard cut at the budget if no natural boundary exists.
            let cutIndex = splitPoint ?? budgetIndex

            let chunk = String(remaining[remaining.startIndex..<cutIndex])
                .trimmingCharacters(in: .whitespaces)
            if !chunk.isEmpty { chunks.append(chunk) }
            remaining = String(remaining[cutIndex...]).trimmingCharacters(in: .whitespaces)
        }

        if !remaining.isEmpty { chunks.append(remaining) }
        return chunks.isEmpty ? [text] : chunks
    }

    // MARK: - Private

    private func makeSession(appContext: AppContext? = nil) -> LanguageModelSession {
        LanguageModelSession(instructions: Self.buildInstructions(for: appContext))
    }
}



