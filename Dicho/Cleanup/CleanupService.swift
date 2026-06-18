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

    func clean(_ text: String) async throws -> String {
        guard case .available = SystemLanguageModel.default.availability else {
            throw CleanupError.unavailable
        }

        let chunks = Self.splitIntoChunks(text)
        var cleaned: [String] = []

        for (index, chunk) in chunks.enumerated() {
            let session: LanguageModelSession
            if index == 0, let pending = pendingSession {
                session = pending
                pendingSession = nil
            } else {
                session = makeSession()
            }
            let response = try await session.respond(
                to: Self.buildPrompt(for: chunk),
                generating: CleanedText.self
            )
            cleaned.append(response.content.text)
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
            return "The user is dictating into a code editor; preserve any token "
                + "that looks like an identifier (camelCase, snake_case, dotted, or "
                + "punctuated), URL, file path, or number exactly as transcribed."
        case .terminal:
            return "The user is dictating into a terminal; preserve commands, "
                + "flags, paths, and shell punctuation exactly as transcribed."
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
            return "The user is dictating into a screenwriting app; preserve scene "
                + "headings (e.g. INT./EXT.), character names (often ALL CAPS), "
                + "parentheticals, transitions (CUT TO:, FADE OUT.), and standard "
                + "screenplay/Fountain formatting exactly as transcribed."
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

    private func makeSession() -> LanguageModelSession {
        LanguageModelSession(instructions: Self.buildInstructions())
    }
}
