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

    // MARK: - Target-app hint (7.3; all hints dropped in M9 round 4, 2026-07-05)

    @Test("hint(for: .generalWriting) returns nil so the prompt stays at baseline")
    func generalWritingProducesNoHint() {
        #expect(CleanupService.hint(for: .generalWriting) == nil)
    }

    @Test("Every category produces no hint — hints were dropped for prompt-size headroom")
    func everyCategoryHasNoHint() {
        // Developer decision 2026-07-05: measured improvement from the hints
        // was insignificant, and instruction growth costs rule-following at
        // this model size. Reintroduce a category hint only with A/B evidence.
        for category in AppCategory.allCases {
            #expect(CleanupService.hint(for: category) == nil, "expected nil hint for \(category)")
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

    @Test("Every category's instructions equal the baseline — no hint is appended")
    func everyCategoryUsesBaselineInstructions() {
        let baseline = CleanupService.buildInstructions()
        for category in AppCategory.allCases {
            let ctx = AppContext(bundleIdentifier: "x", localizedName: "x", category: category)
            #expect(CleanupService.buildInstructions(for: ctx) == baseline, "expected baseline instructions for \(category)")
        }
    }

    @Test("Forbidden-actions block is present regardless of app context")
    func forbiddenActionsPreservedWithContext() {
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

    // MARK: - Pause-repair + continuity rules (M9)

    @Test("Instructions include the pause-repair rule with its worked example, before FORBIDDEN")
    func instructionsIncludePauseRepairRule() {
        let instructions = CleanupService.buildInstructions()
        #expect(instructions.localizedCaseInsensitiveContains("pause"))
        #expect(instructions.localizedCaseInsensitiveContains("mid-sentence"))
        // The "went to the store" worked example is what the 3B model follows.
        #expect(instructions.localizedCaseInsensitiveContains("went to the store"))

        // The rule must sit BEFORE the FORBIDDEN block so it reads as ordinary
        // cleanup guidance, not an override of the core contract.
        guard
            let pauseRange = instructions.range(of: "pause", options: .caseInsensitive),
            let forbiddenRange = instructions.range(of: "FORBIDDEN")
        else {
            Issue.record("Expected both the pause rule and the FORBIDDEN block")
            return
        }
        #expect(pauseRange.lowerBound < forbiddenRange.lowerBound)
    }

    @Test("Instructions include a cross-chunk consistency line")
    func instructionsIncludeContinuityLine() {
        let instructions = CleanupService.buildInstructions()
        #expect(instructions.localizedCaseInsensitiveContains("consistent"))
    }

    @Test("Continuity rule prefers the most complete form over the earliest mention")
    func continuityRulePrefersMostCompleteForm() {
        // When ASR hears the same name two ways ("nicholas F" early,
        // "nicholas ave" later), anchoring on the EARLIEST mention propagates
        // the mis-hearing (M9 manual check 1). The rule must prefer the most
        // complete/plausible form instead.
        let instructions = CleanupService.buildInstructions()
        #expect(instructions.localizedCaseInsensitiveContains("most complete"))
        #expect(!instructions.localizedCaseInsensitiveContains("appear earlier"))
    }

    @Test("Pause-repair rule defers to self-correction so 'Tuesday — no wait, Friday' still resolves to Friday")
    func pauseRepairDefersToSelfCorrection() {
        let instructions = CleanupService.buildInstructions()
        // The carve-out must state that pause repair does not override self-correction.
        #expect(instructions.localizedCaseInsensitiveContains("never overrides the self-correction"))
        // The em-dash self-correction example appears in both rules (self-correction +
        // the pause-repair carve-out), so "no wait" is present more than once.
        let noWaitOccurrences = instructions.components(separatedBy: "no wait").count - 1
        #expect(noWaitOccurrences >= 2)
        // And the carve-out spells out the wrong output it must avoid.
        #expect(instructions.contains("never \"Tuesday, no wait, Friday\""))
    }

    // MARK: - Comma-form self-correction (M9 retest fix, 2026-07-02)

    @Test("Self-correction shows the comma-form 'no wait' worked example")
    func instructionsIncludeCommaFormNoWaitExample() {
        // The transcriber emits commas, not em dashes, around correction markers.
        // The worked example must match transcript-shaped input or the on-device
        // model doesn't fire on it (M9 manual check 4: "correction" and
        // "scratch that" — both shown with commas — worked; "no wait" didn't).
        let instructions = CleanupService.buildInstructions()
        #expect(instructions.contains("\"Tuesday, no wait, Friday\" → \"Friday\""))
    }

    @Test("Self-correction keeps the em-dash 'no wait' worked example alongside the comma form")
    func instructionsKeepEmDashNoWaitExample() {
        let instructions = CleanupService.buildInstructions()
        #expect(instructions.contains("\"Tuesday — no wait, Friday\" → \"Friday\""))
    }

    @Test("Self-correction states that the marker's preceding punctuation never changes the rule")
    func instructionsMakeMarkerPunctuationAgnostic() {
        let instructions = CleanupService.buildInstructions()
        #expect(instructions.localizedCaseInsensitiveContains("comma, period, or dash"))
    }

    // MARK: - Split-marker self-correction (M9 round 4, 2026-07-05)

    @Test("Self-correction covers markers with punctuation inside them")
    func instructionsCoverSplitMarkerForm() {
        // The transcriber can render the marker as "No, wait" — comma inside,
        // capitalized, starting a new sentence. The model punctuated that form
        // instead of applying the correction (round-3 retest).
        let instructions = CleanupService.buildInstructions()
        #expect(instructions.contains("no, wait"))
    }

    @Test("Self-correction shows the sentence-initial split-marker worked example")
    func instructionsIncludeSplitMarkerExample() {
        let instructions = CleanupService.buildInstructions()
        #expect(instructions.contains("the meeting is on Tuesday. No, wait on Thursday"))
        #expect(instructions.contains("The meeting is on Thursday"))
    }

    @Test("Self-correction shows the fully unpunctuated raw-ASR worked example")
    func instructionsIncludeUnpunctuatedMarkerExample() {
        let instructions = CleanupService.buildInstructions()
        #expect(instructions.contains("the meeting is on Tuesday no wait on Thursday"))
    }

    // MARK: - Failing-shape example rewrites (M12 eval iteration 2)

    @Test("Scratch-that example shows the sentence-split marker shape")
    func scratchThatExampleIsSentenceSplit() {
        // Baseline evidence (M12.8): "…to Sarah. Scratch that, to Miguel."
        // survived cleanup 5/5; the old example only showed the inline comma
        // form. Iteration-1 lesson: example vocabulary must NOT mirror fixture
        // text (input-echo failure), hence paint/blue/green.
        let instructions = CleanupService.buildInstructions()
        #expect(instructions.contains("paint the door blue. Scratch that, paint it green."))
        #expect(instructions.contains("paint the door green."))
    }

    @Test("Correction example shows the mid-sentence continuation shape")
    func correctionExampleIsMidSentenceContinuation() {
        // Baseline evidence (M12.8): mid-sentence corrections where the
        // sentence continues after the replacement ("…thirty percent more")
        // survived cleanup 5/5; every old example ended the clause at the
        // replacement.
        let instructions = CleanupService.buildInstructions()
        #expect(instructions.contains("it costs eight, correction, nine dollars per crate"))
        #expect(instructions.contains("it costs nine dollars per crate"))
    }

    @Test("Self-correction rule sits at the top of the rule list, before filler removal")
    func selfCorrectionRuleComesFirst() {
        // Priority position: the on-device model weights early instructions
        // more heavily, and self-correction is the rule that keeps regressing.
        let instructions = CleanupService.buildInstructions()
        guard
            let correctionRange = instructions.range(of: "self-correction", options: .caseInsensitive),
            let fillerRange = instructions.range(of: "filler", options: .caseInsensitive)
        else {
            Issue.record("Expected both the self-correction and filler rules")
            return
        }
        #expect(correctionRange.lowerBound < fillerRange.lowerBound)
    }

    // MARK: - Contextual mis-transcription repair (M9 retest fix, 2026-07-05)

    @Test("Instructions include the mis-transcription repair rule with all three conditions, before FORBIDDEN")
    func instructionsIncludeMisTranscriptionRepairRule() {
        // ESL/accented speech produces near-homophone ASR errors ("take the
        // boss" for bus) that context makes unambiguous; the model needs
        // explicit — and tightly bounded — permission to repair them.
        let instructions = CleanupService.buildInstructions()
        #expect(instructions.localizedCaseInsensitiveContains("sounds like"))
        #expect(instructions.localizedCaseInsensitiveContains("nonsensical"))
        #expect(instructions.localizedCaseInsensitiveContains("unambiguous"))

        guard
            let ruleRange = instructions.range(of: "sounds like", options: .caseInsensitive),
            let forbiddenRange = instructions.range(of: "FORBIDDEN")
        else {
            Issue.record("Expected both the repair rule and the FORBIDDEN block")
            return
        }
        #expect(ruleRange.lowerBound < forbiddenRange.lowerBound)
    }

    @Test("Mis-transcription repair shows both worked examples")
    func misTranscriptionRepairHasWorkedExamples() {
        let instructions = CleanupService.buildInstructions()
        #expect(instructions.contains("take the boss to get to town"))
        #expect(instructions.contains("take the bus to get to town"))
        #expect(instructions.contains("hand over every time to my mother"))
        #expect(instructions.contains("hand over every dime to my mother"))
    }

    @Test("Mis-transcription repair carries the uncertainty guard")
    func misTranscriptionRepairHasUncertaintyGuard() {
        let instructions = CleanupService.buildInstructions()
        #expect(instructions.localizedCaseInsensitiveContains("keep the transcribed word"))
    }

    @Test("FORBIDDEN block names the repair rule among its exceptions")
    func forbiddenBlockReferencesRepairException() {
        // Without the cross-reference the two rules contradict and the 3B model
        // resolves the conflict unpredictably.
        let instructions = CleanupService.buildInstructions()
        guard let forbiddenRange = instructions.range(of: "FORBIDDEN") else {
            Issue.record("Expected the FORBIDDEN block")
            return
        }
        let forbiddenBlock = instructions[forbiddenRange.lowerBound...]
        #expect(forbiddenBlock.localizedCaseInsensitiveContains("mis-transcription repair"))
    }

    @Test("FORBIDDEN block licenses self-correction to drop abandoned numbers")
    func forbiddenBlockReferencesSelfCorrectionException() {
        // The no-numbers-altered clause must name self-correction as an
        // exception, or it literally denies the self-correction rule the right
        // to drop an abandoned number ("20, no wait 30") — the exact residual
        // class stuck across iterations 1–4.
        let instructions = CleanupService.buildInstructions()
        guard let forbiddenRange = instructions.range(of: "FORBIDDEN") else {
            Issue.record("Expected the FORBIDDEN block")
            return
        }
        let forbiddenBlock = instructions[forbiddenRange.lowerBound...]
        #expect(forbiddenBlock.localizedCaseInsensitiveContains("self-correction"))
        #expect(forbiddenBlock.localizedCaseInsensitiveContains("abandoned number"))
    }
}

// MARK: - Session-lifecycle suite (M9, plan §A2)

/// Error used to verify that unrecognized session errors propagate out of `clean`.
private enum SessionTestError: Error, Equatable {
    case boom
}

/// Marker prefix a scripted session prepends to signal "this chunk was cleaned",
/// so tests can distinguish cleaned output from a raw-fallback chunk.
private let cleanedMarkerPrefix = "CLEANED::"

/// Builds a transcript of three ~1500-char sentences (~4500 chars total) that
/// `splitIntoChunks` divides into exactly three chunks at the 2048-char budget.
@MainActor
private func makeThreeChunkInput() -> String {
    (1...3).map { i in
        String(repeating: "word\(i) ", count: 250).trimmingCharacters(in: .whitespaces) + "."
    }.joined(separator: " ")
}

/// Scripted `.succeed` transform: strips the prompt boilerplate and returns the
/// chunk prefixed with `cleanedMarkerPrefix`, so the join order and cleaned-vs-raw
/// distinction are both observable in the final result.
@MainActor
private func markCleaned(_ prompt: String) -> String {
    let promptPrefix = CleanupService.buildPrompt(for: "")
    let chunk = prompt.hasPrefix(promptPrefix) ? String(prompt.dropFirst(promptPrefix.count)) : prompt
    return cleanedMarkerPrefix + chunk
}

/// Counts how many chunks were marked cleaned in the joined result.
private func cleanedCount(in result: String) -> Int {
    result.components(separatedBy: cleanedMarkerPrefix).count - 1
}

@Suite("CleanupService — shared-session lifecycle (fakes, no live model)")
@MainActor
struct CleanupServiceSessionLifecycleTests {

    @Test("A single shared session cleans all three chunks, joined in order")
    func sharedSessionAcrossChunks() async throws {
        let input = makeThreeChunkInput()
        let chunks = CleanupService.splitIntoChunks(input)
        #expect(chunks.count == 3)

        let session = FakeCleanupModelSession([.succeed(markCleaned)])
        let factory = FakeSessionFactory([session])
        let service = CleanupService(chunkTimeout: 0.1, isModelAvailable: { true }, makeSession: factory.make)

        let result = try await service.clean(input, appContext: nil)

        #expect(factory.sessionsCreated == 1)
        #expect(session.prompts.count == 3)
        let expected = chunks.map { cleanedMarkerPrefix + $0 }.joined(separator: " ")
        #expect(result == expected)
    }

    @Test("A prewarmed session is reused for all chunks — no extra session created")
    func prewarmedSessionReused() async throws {
        let input = makeThreeChunkInput()
        let session = FakeCleanupModelSession([.succeed(markCleaned)])
        let factory = FakeSessionFactory([session])
        let service = CleanupService(chunkTimeout: 0.1, isModelAvailable: { true }, makeSession: factory.make)

        service.prewarm()
        let result = try await service.clean(input, appContext: nil)

        #expect(factory.sessionsCreated == 1)
        #expect(session.prewarmCount == 1)
        #expect(session.prompts.count == 3)
        #expect(cleanedCount(in: result) == 3)
    }

    @Test("An app context no longer discards the prewarmed session — hints are gone, so it is reused")
    func appContextReusesPrewarmedSession() async throws {
        // Inverse of the pre-round-4 behavior: with hints dropped (2026-07-05)
        // every category's instructions equal the baseline, so the prewarmed
        // session is never stale and no rebuild happens at record-stop.
        let input = makeThreeChunkInput()
        let prewarmed = FakeCleanupModelSession([.succeed(markCleaned)])
        let factory = FakeSessionFactory([prewarmed])
        let service = CleanupService(chunkTimeout: 0.1, isModelAvailable: { true }, makeSession: factory.make)

        service.prewarm()
        let email = AppContext(bundleIdentifier: "com.apple.mail", localizedName: "Mail", category: .email)
        _ = try await service.clean(input, appContext: email)

        #expect(factory.sessionsCreated == 1)
        #expect(prewarmed.prewarmCount == 1)
        #expect(prewarmed.prompts.count == 3)      // served all chunks
        #expect(factory.instructionsUsed.last == CleanupService.buildInstructions())
    }

    @Test("Context-window overflow rotates the session and retries the chunk")
    func overflowRotatesAndRetries() async throws {
        let input = makeThreeChunkInput()
        let session1 = FakeCleanupModelSession([.succeed(markCleaned), .throwOverflow])
        let session2 = FakeCleanupModelSession([.succeed(markCleaned)])
        let factory = FakeSessionFactory([session1, session2])
        let service = CleanupService(chunkTimeout: 0.1, isModelAvailable: { true }, makeSession: factory.make)

        let result = try await service.clean(input, appContext: nil)

        #expect(factory.sessionsCreated == 2)
        #expect(session1.prompts.count == 2)   // chunk1 ok, chunk2 overflow
        #expect(session2.prompts.count == 2)   // chunk2 retry ok, chunk3 ok
        #expect(cleanedCount(in: result) == 3) // all three cleaned end-to-end
    }

    @Test("When the overflow retry also overflows, that chunk is raw and later chunks stay on session 2")
    func overflowRetryFailsFallsBackRaw() async throws {
        let input = makeThreeChunkInput()
        let chunks = CleanupService.splitIntoChunks(input)
        let session1 = FakeCleanupModelSession([.succeed(markCleaned), .throwOverflow])
        let session2 = FakeCleanupModelSession([.throwOverflow, .succeed(markCleaned)])
        let factory = FakeSessionFactory([session1, session2])
        let service = CleanupService(chunkTimeout: 0.1, isModelAvailable: { true }, makeSession: factory.make)

        let result = try await service.clean(input, appContext: nil)

        #expect(factory.sessionsCreated == 2)
        #expect(session2.prompts.count == 2)     // chunk2 retry (overflow), chunk3 (ok)
        #expect(cleanedCount(in: result) == 2)   // chunk1 & chunk3 cleaned; chunk2 raw
        #expect(result.contains(chunks[1]))      // raw chunk2 present verbatim
    }

    @Test("A timed-out chunk is inserted raw and rotates in a fresh session for later chunks")
    func timeoutInsertsRawAndRotates() async throws {
        let input = makeThreeChunkInput()
        let chunks = CleanupService.splitIntoChunks(input)
        let session1 = FakeCleanupModelSession([.succeed(markCleaned), .sleepForever])
        let session2 = FakeCleanupModelSession([.succeed(markCleaned)])
        let factory = FakeSessionFactory([session1, session2])
        let service = CleanupService(chunkTimeout: 0.1, isModelAvailable: { true }, makeSession: factory.make)

        let result = try await service.clean(input, appContext: nil)

        #expect(factory.sessionsCreated == 2)
        #expect(session2.prompts.count == 1)     // only chunk3 (chunk2 timed out on session1)
        #expect(cleanedCount(in: result) == 2)   // chunk1 & chunk3 cleaned; chunk2 raw
        #expect(result.contains(chunks[1]))      // raw chunk2 present verbatim
    }

    @Test("Schema leakage inserts the chunk raw WITHOUT rotating the session")
    func leakageInsertsRawKeepsSession() async throws {
        let input = makeThreeChunkInput()
        let chunks = CleanupService.splitIntoChunks(input)
        let session = FakeCleanupModelSession([.succeed(markCleaned), .succeedWithLeakage, .succeed(markCleaned)])
        let factory = FakeSessionFactory([session])
        let service = CleanupService(chunkTimeout: 0.1, isModelAvailable: { true }, makeSession: factory.make)

        let result = try await service.clean(input, appContext: nil)

        #expect(factory.sessionsCreated == 1)    // NOT rotated — the session is still healthy
        #expect(session.prompts.count == 3)      // all three chunks on the same session
        #expect(cleanedCount(in: result) == 2)   // chunk1 & chunk3 cleaned; chunk2 raw
        #expect(result.contains(chunks[1]))      // raw chunk2 present verbatim
    }

    @Test("A guardrail-refused chunk is inserted raw WITHOUT rotating the session or failing the call")
    func guardrailInsertsRawKeepsSession() async throws {
        let input = makeThreeChunkInput()
        let chunks = CleanupService.splitIntoChunks(input)
        let session = FakeCleanupModelSession([.succeed(markCleaned), .throwGuardrail, .succeed(markCleaned)])
        let factory = FakeSessionFactory([session])
        let service = CleanupService(chunkTimeout: 0.1, isModelAvailable: { true }, makeSession: factory.make)

        let result = try await service.clean(input, appContext: nil)

        #expect(factory.sessionsCreated == 1)    // NOT rotated — the session is still healthy
        #expect(session.prompts.count == 3)      // all three chunks on the same session
        #expect(cleanedCount(in: result) == 2)   // chunk1 & chunk3 cleaned; chunk2 raw
        #expect(result.contains(chunks[1]))      // raw chunk2 present verbatim
    }

    @Test("A guardrail refusal during the overflow retry falls back to the raw chunk")
    func guardrailDuringOverflowRetryFallsBackRaw() async throws {
        let input = makeThreeChunkInput()
        let chunks = CleanupService.splitIntoChunks(input)
        let session1 = FakeCleanupModelSession([.succeed(markCleaned), .throwOverflow])
        let session2 = FakeCleanupModelSession([.throwGuardrail, .succeed(markCleaned)])
        let factory = FakeSessionFactory([session1, session2])
        let service = CleanupService(chunkTimeout: 0.1, isModelAvailable: { true }, makeSession: factory.make)

        let result = try await service.clean(input, appContext: nil)

        #expect(factory.sessionsCreated == 2)
        #expect(session2.prompts.count == 2)     // chunk2 retry (guardrail), chunk3 (ok)
        #expect(cleanedCount(in: result) == 2)   // chunk1 & chunk3 cleaned; chunk2 raw
        #expect(result.contains(chunks[1]))      // raw chunk2 present verbatim
    }

    @Test("An unrecognized (non-overflow, non-timeout) session error propagates out of clean")
    func unrecognizedErrorPropagates() async {
        let input = makeThreeChunkInput()
        let session = FakeCleanupModelSession([.succeed(markCleaned), .throwOther(SessionTestError.boom)])
        let factory = FakeSessionFactory([session])
        let service = CleanupService(chunkTimeout: 0.1, isModelAvailable: { true }, makeSession: factory.make)

        await #expect(throws: SessionTestError.self) {
            _ = try await service.clean(input, appContext: nil)
        }
    }
}
