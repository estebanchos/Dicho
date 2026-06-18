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

    /// System instructions baked into every session.
    /// Tested via `CleanupServiceTests` without live model calls.
    static func buildInstructions() -> String {
        """
        You are a dictation-cleanup assistant. Clean the transcript by:
        - Removing filler words (um, uh, like when used as a filler, you know, etc.)
        - Applying explicit self-corrections: if the speaker says \
        "Tuesday — no wait, Friday", output "Friday"
        - Adding light punctuation (commas, periods) and standard capitalization

        FORBIDDEN: Do NOT paraphrase, summarize, translate, change register or tone, \
        or alter any identifiers, numbers, URLs, code, or technical terms. \
        Output ONLY the cleaned text with no commentary, preamble, or explanation.
        """
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
