import Foundation
import FoundationModels

@Generable
struct CleanedText {
    @Guide(description: "The cleaned text with filler words removed and self-corrections applied")
    var text: String
}

/// Production cleanup service using Foundation Models guided generation.
///
/// A single `LanguageModelSession` (behind the `CleanupModelSessioning` seam) is
/// prewarmed when recording starts and then **reused across every chunk** of a
/// dictation, so later chunks retain the context of earlier ones (name/address
/// consistency, pause-seam repair). Long transcripts are split into ≤512-token
/// chunks and cleaned serially, then joined.
///
/// This class owns the **per-chunk timeout**: each chunk's model turn is raced
/// against `chunkTimeout` (see `cleanChunk`). A timed-out session may still be
/// responding — and `LanguageModelSession` forbids concurrent requests — so a
/// timeout (or a context-window overflow) rotates in a fresh session before the
/// next chunk. Collaborators are injectable so the reuse/rotation/timeout logic
/// is unit-testable without live FoundationModels calls.
@MainActor
final class CleanupService: CleanupServicing {

    private let chunkTimeout: TimeInterval
    private let isModelAvailable: @MainActor () -> Bool
    private let makeSessionImpl: @MainActor (String) -> any CleanupModelSessioning

    private var pendingSession: (any CleanupModelSessioning)?

    /// - Parameters:
    ///   - chunkTimeout: per-chunk model-response timeout; a chunk that exceeds
    ///     it is inserted raw and the session is rotated. Defaults to
    ///     `Constants.cleanupChunkTimeout` when `nil` (resolved in the body
    ///     rather than the default argument, which is a nonisolated context and
    ///     cannot reference the main-actor-isolated constant).
    ///   - isModelAvailable: injectable availability check so behavior tests do
    ///     not depend on the test machine's Apple Intelligence state.
    ///   - makeSession: factory building a session from instruction text.
    init(
        chunkTimeout: TimeInterval? = nil,
        isModelAvailable: @escaping @MainActor () -> Bool = {
            if case .available = SystemLanguageModel.default.availability { true } else { false }
        },
        makeSession: @escaping @MainActor (String) -> any CleanupModelSessioning = {
            FoundationModelCleanupSession(instructions: $0)
        }
    ) {
        self.chunkTimeout = chunkTimeout ?? Constants.cleanupChunkTimeout
        self.isModelAvailable = isModelAvailable
        self.makeSessionImpl = makeSession
    }

    // MARK: - CleanupServicing

    func prewarm() {
        guard isModelAvailable() else { return }
        let session = makeSessionImpl(Self.buildInstructions())
        session.prewarm()
        pendingSession = session
    }

    func clean(_ text: String, appContext: AppContext?) async throws -> String {
        guard isModelAvailable() else {
            throw CleanupError.unavailable
        }

        // Short-input bypass: very short inputs (single tokens / abbreviations)
        // are where the on-device model is most likely to hallucinate or echo
        // its own system prompt, and cleanup barely helps anyway.
        if Self.shouldBypassCleanup(for: text) {
            return text
        }

        let chunks = Self.splitIntoChunks(text)
        var session = resolveInitialSession(appContext: appContext)
        var cleaned: [String] = []

        for chunk in chunks {
            switch try await cleanChunk(chunk, session: session) {
            case .cleaned(let cleanedChunk):
                cleaned.append(cleanedChunk)
            case .rawFallback:
                // Leakage or guardrail refusal: keep the session (it's still
                // healthy) but insert this chunk raw.
                cleaned.append(chunk)
            case .timedOut:
                // The session may still be responding; rotate before the next chunk.
                cleaned.append(chunk)
                session = makeSessionImpl(Self.buildInstructions(for: appContext))
            case .overflowed:
                // Window full: rotate to a fresh session and retry this chunk once.
                session = makeSessionImpl(Self.buildInstructions(for: appContext))
                switch try await cleanChunk(chunk, session: session) {
                case .cleaned(let cleanedChunk):
                    cleaned.append(cleanedChunk)
                case .timedOut:
                    // Retry timed out — insert raw and rotate again for later chunks.
                    cleaned.append(chunk)
                    session = makeSessionImpl(Self.buildInstructions(for: appContext))
                default:
                    // Second overflow or leakage: insert raw, keep this session.
                    cleaned.append(chunk)
                }
            }
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
        - Removing filler words (um, uhm, uh, er, ah, hmm, "like" when used as a filler, \
        "you know", and similar hesitation markers).
        - Applying explicit self-corrections. When the speaker marks a correction with one \
        of these phrases, output ONLY the replacement and drop the abandoned phrase before it. \
        The marker may be preceded by a comma, period, or dash — that punctuation never \
        changes the rule:
            • "X, no wait, Y" → "Y"  (e.g. "Tuesday, no wait, Friday" → "Friday"; \
        "Tuesday — no wait, Friday" → "Friday")
            • "X, scratch that, Y" → "Y"  (e.g. "buy milk, scratch that, buy bread" → "buy bread")
            • "X, correction, Y" → "Y"  (e.g. "the meeting is Tuesday, correction, \
        the meeting is Wednesday" → "the meeting is Wednesday")
        - Adding light punctuation (commas, periods) and standard capitalization.
        - Repairing pause artifacts: the transcriber sometimes inserts a period or comma \
        where the speaker merely paused mid-sentence, capitalizing the next word. When the \
        text clearly continues the same sentence across such a break, remove the spurious \
        punctuation and fix the capitalization:
            • "we went to the store. And then we left" → "we went to the store, and then we left"
        Only repair breaks that are clearly mid-sentence; keep genuine sentence endings. \
        This repair NEVER overrides the self-correction rule above: when the break is part \
        of a self-correction (for example an em dash or comma before "no wait", "scratch \
        that", or "correction"), apply the self-correction — drop the abandoned text — \
        rather than merely swapping the punctuation. \
        ("Tuesday — no wait, Friday" → "Friday", never "Tuesday, no wait, Friday".)
        - Keeping names, addresses, and terms consistent across this conversation's \
        transcript chunks. If the same name or term appears in differing forms, use the \
        most complete and plausible form for every mention — not necessarily the form \
        that appeared first.

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

    /// Outcome of a single chunk's cleanup turn.
    private enum ChunkOutcome {
        /// The model returned usable cleaned text.
        case cleaned(String)
        /// The model echoed system-prompt artifacts or its safety guardrails
        /// refused the content; caller should insert the chunk raw. The session
        /// itself is still healthy, so it is kept for later chunks.
        case rawFallback
        /// The turn exceeded `chunkTimeout`.
        case timedOut
        /// The session's context window overflowed.
        case overflowed
    }

    /// Picks the session for the first chunk. Reuses the prewarmed baseline
    /// session when the app context has no hint; otherwise discards it and builds
    /// a context-aware session (the prewarmed instructions would be stale).
    private func resolveInitialSession(appContext: AppContext?) -> any CleanupModelSessioning {
        let needsContextAwareSession = Self.hint(for: appContext?.category ?? .generalWriting) != nil
        if needsContextAwareSession {
            pendingSession = nil
            return makeSessionImpl(Self.buildInstructions(for: appContext))
        }
        if let pending = pendingSession {
            pendingSession = nil
            return pending
        }
        return makeSessionImpl(Self.buildInstructions(for: appContext))
    }

    /// Cleans one chunk on `session`, racing the model response against
    /// `chunkTimeout`. Maps overflow, timeout, and leakage into `ChunkOutcome`;
    /// any other error is rethrown to the caller (the coordinator falls back to
    /// the raw transcript, so caller-visible behavior is unchanged).
    private func cleanChunk(
        _ chunk: String,
        session: any CleanupModelSessioning
    ) async throws -> ChunkOutcome {
        let prompt = Self.buildPrompt(for: chunk)
        let timeout = chunkTimeout
        do {
            let cleaned = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await session.respondCleanedText(to: prompt) }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    throw CleanupError.timeout
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
            // Defensive: if the model echoed its guided-generation schema or any
            // other system-prompt artifact, fall back to the raw chunk rather
            // than insert garbage into the user's document.
            return Self.isLikelyModelLeakage(cleaned) ? .rawFallback : .cleaned(cleaned)
        } catch CleanupError.timeout {
            return .timedOut
        } catch CleanupSessionError.contextWindowExceeded {
            return .overflowed
        } catch CleanupSessionError.guardrailTriggered {
            // Guardrails refused this chunk's content (possible even with the
            // permissive-transformations model on extreme content). The chunk
            // is inserted raw; one refusal must not degrade the whole dictation.
            return .rawFallback
        }
    }
}



