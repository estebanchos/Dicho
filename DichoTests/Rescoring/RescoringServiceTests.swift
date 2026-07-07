import Foundation
import Testing
@testable import Dicho

/// `RescoringService` behavior with fakes (TASKS.md 10.4): gate-bounded model
/// use, index-based selection, and total (never-throwing) fallback to the top
/// hypothesis. No live FoundationModels calls.
@Suite("RescoringService — gate + stateless selector (fakes, no live model)")
@MainActor
struct RescoringServiceTests {

    /// A confident segment the gate must pass through untouched.
    private func confident(_ text: String) -> TranscriptUpdate {
        TranscriptUpdate(text: text, range: nil, isFinal: true, alternatives: [text], confidence: 0.99)
    }

    /// An ambiguous segment the gate must route to the selector.
    private func ambiguous(_ text: String, alternatives: [String]) -> TranscriptUpdate {
        TranscriptUpdate(text: text, range: nil, isFinal: true, alternatives: alternatives, confidence: 0.5)
    }

    private func makeService(
        _ factory: FakeRescoringSessionFactory,
        timeout: TimeInterval = 0.1
    ) -> RescoringService {
        RescoringService(segmentTimeout: timeout, isModelAvailable: { true }, makeSession: factory.make)
    }

    @Test("Confident segments reassemble without ever touching the model")
    func passThroughNeverTouchesModel() async {
        let factory = FakeRescoringSessionFactory([])
        let service = makeService(factory)

        let result = await service.rescore([confident(" she made me"), confident(" who I am today.")])

        #expect(result == "she made me who I am today.")
        #expect(factory.sessionsCreated == 0)
    }

    @Test("An ambiguous segment is replaced by the model-chosen candidate")
    func ambiguousSegmentUsesChosenCandidate() async {
        let session = FakeRescoringModelSession([.returnIndex(1)])
        let factory = FakeRescoringSessionFactory([session])
        let service = makeService(factory)

        let result = await service.rescore([
            confident(" I worked at the local"),
            ambiguous(" daily", alternatives: [" daily", " deli"]),
            confident(" making sandwiches."),
        ])

        #expect(result == "I worked at the local deli making sandwiches.")
        #expect(factory.sessionsCreated == 1)
    }

    @Test("A punctuation-only selector choice keeps the top hypothesis — no punctuation churn")
    func punctuationOnlyChoiceKeepsTopHypothesis() async {
        // Field test 2026-07-07: the gate fired on ' man.' because the candidate
        // SET contained a lexically distinct entry (' man, you'), but the
        // selector then picked ' man,' — spending a model call to degrade a
        // sentence boundary. A choice that is lexically identical to the top
        // hypothesis must snap back to it.
        let session = FakeRescoringModelSession([.returnIndex(1)])
        let factory = FakeRescoringSessionFactory([session])
        let service = makeService(factory)

        let result = await service.rescore([
            ambiguous(" man.", alternatives: [" man.", " man,", " man, you"]),
        ])

        #expect(result == "man.")
        #expect(session.prompts.count == 1)   // the selector DID run; the snap is post-selection
    }

    @Test("An out-of-range index falls back to the top hypothesis")
    func outOfRangeIndexFallsBack() async {
        let session = FakeRescoringModelSession([.returnIndex(7)])
        let factory = FakeRescoringSessionFactory([session])
        let service = makeService(factory)

        let result = await service.rescore([ambiguous(" daily", alternatives: [" daily", " deli"])])

        #expect(result == "daily")
    }

    @Test("A selector error falls back to the top hypothesis — rescore never throws")
    func sessionErrorFallsBack() async {
        let session = FakeRescoringModelSession([.throwError])
        let factory = FakeRescoringSessionFactory([session])
        let service = makeService(factory)

        let result = await service.rescore([ambiguous(" daily", alternatives: [" daily", " deli"])])

        #expect(result == "daily")
    }

    @Test("A selector timeout falls back to the top hypothesis")
    func timeoutFallsBack() async {
        let session = FakeRescoringModelSession([.sleepForever])
        let factory = FakeRescoringSessionFactory([session])
        let service = makeService(factory, timeout: 0.05)

        let result = await service.rescore([ambiguous(" daily", alternatives: [" daily", " deli"])])

        #expect(result == "daily")
    }

    @Test("The prewarmed session serves the first ambiguous segment; later ones get fresh sessions")
    func prewarmedSessionConsumedFirst() async {
        let first = FakeRescoringModelSession([.returnIndex(0)])
        let second = FakeRescoringModelSession([.returnIndex(0)])
        let factory = FakeRescoringSessionFactory([first, second])
        let service = makeService(factory)

        service.prewarm()
        #expect(first.prewarmCount == 1)

        _ = await service.rescore([
            ambiguous(" daily", alternatives: [" daily", " deli"]),
            ambiguous(" today.", alternatives: [" today.", " day."]),
        ])

        // One session from prewarm + one fresh for the second segment —
        // selections are stateless, no session is reused across segments.
        #expect(factory.sessionsCreated == 2)
        #expect(first.prompts.count == 1)
        #expect(second.prompts.count == 1)
    }

    @Test("The selector prompt numbers every candidate and includes the preceding context")
    func promptCarriesCandidatesAndContext() async {
        let session = FakeRescoringModelSession([.returnIndex(0)])
        let factory = FakeRescoringSessionFactory([session])
        let service = makeService(factory)

        _ = await service.rescore([
            confident(" I worked at the local"),
            ambiguous(" daily", alternatives: [" daily", " deli"]),
        ])

        let prompt = session.prompts.first ?? ""
        #expect(prompt.contains("0."))
        #expect(prompt.contains("1."))
        #expect(prompt.contains("daily"))
        #expect(prompt.contains("deli"))
        #expect(prompt.contains("I worked at the local"))
    }

    @Test("Selection context is built from preceding top hypotheses, enabling concurrency")
    func contextUsesTopHypotheses() async {
        // Round 3 (2026-07-07): contexts are precomputed from segment top
        // hypotheses — NOT from earlier chosen candidates — so selections can
        // run concurrently. The first segment being replaced must not change
        // the second segment's context.
        let first = FakeRescoringModelSession([.returnIndex(1)])   // replaces " daily" → " deli"
        let second = FakeRescoringModelSession([.returnIndex(0)])
        let factory = FakeRescoringSessionFactory([first, second])
        let service = makeService(factory)

        _ = await service.rescore([
            ambiguous(" daily", alternatives: [" daily", " deli"]),
            confident(" making sandwiches, and"),
            ambiguous(" I chip in", alternatives: [" I chip in", " I'd chip in"]),
        ])

        let prompt = second.prompts.first ?? ""
        #expect(prompt.contains("daily"))            // top hypothesis, even though replaced
        #expect(prompt.contains("making sandwiches"))
        #expect(!prompt.contains("deli"))
    }

    @Test("Ambiguous segments are selected concurrently — two timeouts cost one timeout window")
    func selectionsRunConcurrently() async {
        // Two sleeping sessions with a 0.5 s timeout: serial execution would
        // take ≥ 1.0 s; concurrent execution finishes in ~one timeout window.
        let factory = FakeRescoringSessionFactory([
            FakeRescoringModelSession([.sleepForever]),
            FakeRescoringModelSession([.sleepForever]),
        ])
        let service = makeService(factory, timeout: 0.5)

        let clock = ContinuousClock()
        let start = clock.now
        let result = await service.rescore([
            ambiguous(" daily", alternatives: [" daily", " deli"]),
            ambiguous(" gonna", alternatives: [" gonna", " going"]),
        ])
        let elapsed = clock.now - start

        #expect(result == "daily gonna")             // both fall back to top hypotheses
        #expect(elapsed < .milliseconds(850), "selections appear to run serially: \(elapsed)")
    }

    @Test("Model unavailable degrades to pure pass-through")
    func modelUnavailablePassesThrough() async {
        let factory = FakeRescoringSessionFactory([])
        let service = RescoringService(
            segmentTimeout: 0.1,
            isModelAvailable: { false },
            makeSession: factory.make
        )

        let result = await service.rescore([ambiguous(" daily", alternatives: [" daily", " deli"])])

        #expect(result == "daily")
        #expect(factory.sessionsCreated == 0)
    }

    @Test("Empty segment list produces an empty transcript")
    func emptySegmentsProduceEmptyString() async {
        let service = makeService(FakeRescoringSessionFactory([]))
        let result = await service.rescore([])
        #expect(result.isEmpty)
    }
}

/// Golden-file checks for the selector prompt text (no live model).
@Suite("RescoringService — selector prompt construction (golden-file)")
@MainActor
struct RescoringPromptTests {

    @Test("Instructions direct index-only selection and forbid inventing text")
    func instructionsAreSelectionOnly() {
        let instructions = RescoringService.buildInstructions()
        #expect(instructions.localizedCaseInsensitiveContains("index"))
        #expect(instructions.localizedCaseInsensitiveContains("candidate"))
        #expect(instructions.localizedCaseInsensitiveContains("never invent"))
    }

    @Test("Instructions bias toward candidate 0 — switching needs clear justification")
    func instructionsBiasTowardTopHypothesis() {
        // Field test 2026-07-07: without this bias the 3B model preferred the
        // formal variant (" gonna"→" going", " gotta"→" got"), producing
        // ungrammatical output.
        let instructions = RescoringService.buildInstructions()
        #expect(instructions.localizedCaseInsensitiveContains("candidate 0"))
        #expect(instructions.localizedCaseInsensitiveContains("most likely"))
        #expect(instructions.localizedCaseInsensitiveContains("if unsure, answer 0"))
    }

    @Test("Instructions forbid formalizing spoken register")
    func instructionsGuardSpokenRegister() {
        let instructions = RescoringService.buildInstructions()
        #expect(instructions.localizedCaseInsensitiveContains("formal"))
        #expect(instructions.contains("gonna"))
    }

    @Test("buildPrompt numbers candidates from zero and embeds the context")
    func promptEmbedsNumberedCandidates() {
        let prompt = RescoringService.buildPrompt(
            candidates: [" daily", " deli"],
            context: "I worked at the local"
        )
        #expect(prompt.contains("0.  daily"))
        #expect(prompt.contains("1.  deli"))
        #expect(prompt.contains("I worked at the local"))
    }
}
