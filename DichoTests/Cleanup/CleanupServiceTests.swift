import Foundation
import Testing
@testable import Dicho

@Suite("CleanupService — prompt construction (golden-file, no live model)")
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
}
