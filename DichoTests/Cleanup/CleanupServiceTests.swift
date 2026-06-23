import Foundation
import Testing
@testable import Dicho

@Suite("CleanupService — prompt construction (golden-file, no live model)")
@MainActor
struct CleanupServiceTests {

    // MARK: - Instructions structure

    @Test("Instructions include filler-word removal directive")
    func instructionsIncludeFillerRemoval() {
        let instructions = CleanupService.buildInstructions()
        #expect(instructions.localizedCaseInsensitiveContains("filler"))
    }

    @Test("Instructions include self-correction directive")
    func instructionsIncludeSelfCorrection() {
        let instructions = CleanupService.buildInstructions()
        #expect(
            instructions.localizedCaseInsensitiveContains("self-correction") ||
            instructions.localizedCaseInsensitiveContains("correction")
        )
    }

    @Test("Instructions explicitly forbid paraphrasing")
    func instructionsForbidParaphrase() {
        let instructions = CleanupService.buildInstructions()
        #expect(instructions.localizedCaseInsensitiveContains("paraphrase"))
    }

    @Test("Instructions explicitly forbid summarizing")
    func instructionsForbidSummarize() {
        let instructions = CleanupService.buildInstructions()
        #expect(
            instructions.localizedCaseInsensitiveContains("summarize") ||
            instructions.localizedCaseInsensitiveContains("summary")
        )
    }

    @Test("Instructions explicitly protect identifiers and technical terms")
    func instructionsProtectTechnicalTerms() {
        let instructions = CleanupService.buildInstructions()
        #expect(
            instructions.localizedCaseInsensitiveContains("identifier") ||
            instructions.localizedCaseInsensitiveContains("technical")
        )
    }

    @Test("Instructions direct output to be cleaned text only with no commentary")
    func instructionsRequireCleanOutputOnly() {
        let instructions = CleanupService.buildInstructions()
        #expect(
            instructions.localizedCaseInsensitiveContains("commentary") ||
            instructions.localizedCaseInsensitiveContains("explanation") ||
            instructions.localizedCaseInsensitiveContains("preamble")
        )
    }

    // MARK: - Prompt structure

    @Test("buildPrompt embeds input text verbatim")
    func buildPromptEmbedsInputVerbatim() {
        let input = "um so let's meet on uh Tuesday — no wait Friday"
        let prompt = CleanupService.buildPrompt(for: input)
        #expect(prompt.contains(input))
    }

    @Test("buildPrompt for different inputs produces different prompts")
    func buildPromptVariesWithInput() {
        let p1 = CleanupService.buildPrompt(for: "hello world")
        let p2 = CleanupService.buildPrompt(for: "goodbye world")
        #expect(p1 != p2)
    }

    // MARK: - Chunking

    @Test("Short text produces a single chunk unchanged")
    func shortTextProducesOneChunk() {
        let text = "Hello, world. This is a short sentence."
        let chunks = CleanupService.splitIntoChunks(text)
        #expect(chunks.count == 1)
        #expect(chunks[0] == text)
    }

    @Test("Text at or below the token budget produces one chunk")
    func textAtBudgetProducesOneChunk() {
        // 100 words × 5 chars = ~500 chars, well under 512 × 4 = 2048
        let text = String(repeating: "word ", count: 100).trimmingCharacters(in: .whitespaces)
        let chunks = CleanupService.splitIntoChunks(text)
        #expect(chunks.count == 1)
    }

    @Test("Long text exceeding the token budget splits into multiple non-empty chunks")
    func longTextSplitsIntoMultipleChunks() {
        // 300 × "longword " = 2700 chars > 512 × 4 = 2048
        let text = String(repeating: "longword ", count: 300).trimmingCharacters(in: .whitespaces)
        let chunks = CleanupService.splitIntoChunks(text)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { !$0.isEmpty })
    }

    @Test("All words are preserved across chunks — no data loss")
    func chunksPreserveAllWords() {
        let text = String(repeating: "longword ", count: 300).trimmingCharacters(in: .whitespaces)
        let chunks = CleanupService.splitIntoChunks(text)
        let originalCount = text.split(separator: " ").count
        let rejoinedCount = chunks.joined(separator: " ").split(separator: " ").count
        #expect(originalCount == rejoinedCount)
    }

    @Test("Each chunk fits within the 4×token-budget character limit")
    func eachChunkFitsInBudget() {
        let charBudget = Constants.cleanupChunkTokenBudget * 4
        let text = String(repeating: "longword ", count: 300).trimmingCharacters(in: .whitespaces)
        let chunks = CleanupService.splitIntoChunks(text)
        #expect(chunks.allSatisfy { $0.count <= charBudget })
    }

    // MARK: - Target-app hint (7.3)

    @Test("hint(for: .generalWriting) returns nil so the prompt stays at baseline")
    func generalWritingProducesNoHint() {
        #expect(CleanupService.hint(for: .generalWriting) == nil)
    }

    @Test("Every non-default category produces a non-empty hint")
    func everyMeaningfulCategoryHasAHint() {
        for category in AppCategory.allCases where category != .generalWriting {
            let h = CleanupService.hint(for: category)
            #expect(h != nil, "expected non-nil hint for \(category)")
            #expect(h?.isEmpty == false)
        }
    }

    @Test("buildInstructions() with no arg matches the .generalWriting / nil-context baseline")
    func baselineEquivalences() {
        let none = CleanupService.buildInstructions()
        let nilCtx = CleanupService.buildInstructions(for: nil)
        let general = CleanupService.buildInstructions(
            for: AppContext(bundleIdentifier: nil, localizedName: nil, category: .generalWriting)
        )
        #expect(none == nilCtx)
        #expect(none == general)
    }

    @Test(
        "Category-specific instructions contain a distinguishing keyword from the hint",
        arguments: [
            (AppCategory.ide, "code editor"),
            (.terminal, "terminal"),
            (.messaging, "informal"),
            (.email, "email"),
            (.browser, "browser"),
            (.notes, "notes"),
            (.scriptWriting, "screenwriting"),
            (.filmEditing, "video/film"),
        ]
    )
    func categoryInstructionsContainKeyword(_ pair: (AppCategory, String)) {
        let (category, keyword) = pair
        let ctx = AppContext(bundleIdentifier: "x", localizedName: "x", category: category)
        let instructions = CleanupService.buildInstructions(for: ctx)
        #expect(instructions.localizedCaseInsensitiveContains(keyword))
    }

    @Test("Forbidden-actions block is preserved when a hint is appended")
    func forbiddenActionsPreservedWithHint() {
        let ide = AppContext(bundleIdentifier: "x", localizedName: "x", category: .ide)
        let instructions = CleanupService.buildInstructions(for: ide)
        // The same five forbidden keywords from the M5 contract must still be present.
        #expect(instructions.localizedCaseInsensitiveContains("paraphrase"))
        #expect(
            instructions.localizedCaseInsensitiveContains("summarize") ||
            instructions.localizedCaseInsensitiveContains("summary")
        )
        #expect(
            instructions.localizedCaseInsensitiveContains("identifier") ||
            instructions.localizedCaseInsensitiveContains("technical")
        )
        #expect(
            instructions.localizedCaseInsensitiveContains("commentary") ||
            instructions.localizedCaseInsensitiveContains("explanation") ||
            instructions.localizedCaseInsensitiveContains("preamble")
        )
    }

    @Test("Hint sits AFTER the FORBIDDEN block so it cannot override the contract")
    func hintFollowsForbiddenBlock() {
        let ide = AppContext(bundleIdentifier: "x", localizedName: "x", category: .ide)
        let instructions = CleanupService.buildInstructions(for: ide)
        guard
            let forbiddenRange = instructions.range(of: "FORBIDDEN", options: .caseInsensitive),
            let hintRange = instructions.range(of: "code editor", options: .caseInsensitive)
        else {
            Issue.record("Expected both FORBIDDEN and hint text in the instructions")
            return
        }
        #expect(forbiddenRange.lowerBound < hintRange.lowerBound)
    }

    // MARK: - scriptWriting hint scoping (M7 post-verification fix, 2026-06-23)

    @Test("scriptWriting hint scopes 'exactly as transcribed' to formatting tokens and preserves cleanup for dialogue/description")
    func scriptWritingHintIsScopedCorrectly() {
        guard let hint = CleanupService.hint(for: .scriptWriting) else {
            Issue.record("scriptWriting hint must be non-nil")
            return
        }
        // Formatting tokens must still be the things preserved.
        #expect(hint.localizedCaseInsensitiveContains("scene"))
        #expect(hint.localizedCaseInsensitiveContains("character"))
        // The hint must explicitly clarify that dialogue/description still get
        // the standard cleanup treatment, so the model does not read
        // "exactly as transcribed" as a global override of self-correction
        // (which is what happened during M7 Final Draft manual testing).
        let mentionsDialogueOrDescription =
            hint.localizedCaseInsensitiveContains("dialogue")
            || hint.localizedCaseInsensitiveContains("description")
        #expect(mentionsDialogueOrDescription)
        let mentionsCleanupRules =
            hint.localizedCaseInsensitiveContains("filler")
            || hint.localizedCaseInsensitiveContains("self-correction")
        #expect(mentionsCleanupRules)
    }

    // MARK: - Short-input bypass (M7 post-verification fix, 2026-06-23)

    @Test(
        "shouldBypassCleanup is true for single-token / abbreviation inputs",
        arguments: ["INT", "yes", "OK", "Wednesday", "hello"]
    )
    func shortInputBypassesCleanup(_ text: String) {
        #expect(CleanupService.shouldBypassCleanup(for: text))
    }

    @Test(
        "shouldBypassCleanup is false for multi-word inputs",
        arguments: [
            "hello world",
            "um so let's meet on Friday",
            "Tuesday afternoon, no wait, Wednesday afternoon",
        ]
    )
    func multiWordInputDoesNotBypass(_ text: String) {
        #expect(!CleanupService.shouldBypassCleanup(for: text))
    }

    @Test("shouldBypassCleanup handles whitespace-only and surrounding whitespace")
    func shouldBypassCleanupWhitespace() {
        #expect(CleanupService.shouldBypassCleanup(for: ""))
        #expect(CleanupService.shouldBypassCleanup(for: "   "))
        #expect(CleanupService.shouldBypassCleanup(for: "\n\n"))
        #expect(CleanupService.shouldBypassCleanup(for: "  INT  "))
        #expect(!CleanupService.shouldBypassCleanup(for: "  hello world  "))
    }

    // MARK: - Schema-leakage detector (M7 post-verification fix, 2026-06-23)

    @Test(
        "isLikelyModelLeakage fires on known guided-generation echo patterns",
        arguments: [
            "response format in json",
            "Schema: { name: foo }",
            "name: CleanedText",
            "INT.\nresponse format in json. name: CleanedText schema: {",
            "I am @Generable",
            "@Guide(description: ...)",
            "RESPONSE FORMAT in JSON",
        ]
    )
    func detectsKnownLeakage(_ text: String) {
        #expect(CleanupService.isLikelyModelLeakage(text))
    }

    @Test(
        "isLikelyModelLeakage allows ordinary cleaned text through (no false positives)",
        arguments: [
            "Let's meet on Friday.",
            "Hello, world.",
            "INT. KITCHEN — DAY",                            // genuine scene heading
            "JSON parsing is hard.",                         // mentions 'JSON', no leak markers
            "The class is named after a person named Clean", // contains 'Clean', not 'CleanedText'
            "The schema designer is here.",                  // contains 'schema' but not 'schema:'
        ]
    )
    func allowsCleanText(_ text: String) {
        #expect(!CleanupService.isLikelyModelLeakage(text))
    }

    // MARK: - Expanded filler / self-correction examples (M7 post-verification, 2026-06-23)

    @Test(
        "Instructions list the expanded hesitation-filler vocabulary",
        arguments: ["um", "uhm", "uh", "er", "ah", "hmm"]
    )
    func instructionsListExpandedFillers(_ filler: String) {
        let instructions = CleanupService.buildInstructions()
        #expect(instructions.localizedCaseInsensitiveContains(filler))
    }

    @Test("Instructions explicitly list 'scratch that' as a self-correction marker")
    func instructionsListScratchThat() {
        let instructions = CleanupService.buildInstructions()
        #expect(instructions.localizedCaseInsensitiveContains("scratch that"))
    }

    @Test("Instructions explicitly list 'correction' as a self-correction marker")
    func instructionsListCorrectionKeyword() {
        let instructions = CleanupService.buildInstructions()
        // Stronger than the existing 'self-correction' check: requires the bare
        // marker word 'correction' (the deliberate trigger) to appear, not just
        // the compound 'self-correction'.
        let lower = instructions.lowercased()
        // Search for "correction" preceded by whitespace/punctuation so the
        // match isn't satisfied solely by "self-correction".
        let asWord = lower.contains(", correction,") || lower.contains(" correction,")
            || lower.contains("correction\"") || lower.contains("\"correction")
        #expect(asWord)
    }

    @Test("Self-correction worked examples remain in the instructions")
    func instructionsKeepOriginalSelfCorrectionExample() {
        // The "Tuesday — no wait, Friday" example is the canonical pattern;
        // it should survive the expansion.
        let instructions = CleanupService.buildInstructions()
        #expect(instructions.contains("no wait"))
        #expect(instructions.localizedCaseInsensitiveContains("Friday"))
    }
}
