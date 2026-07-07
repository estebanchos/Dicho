import Foundation
import Testing
@testable import Dicho

/// Pure gate logic for M10 rescoring (TASKS.md 10.3): only genuinely ambiguous
/// FINAL segments go to the model selector; everything else passes through
/// untouched. No model, no Speech — plain value-type decisions.
@Suite("RescoringGate — deterministic pass-through vs rescore (M10)")
struct RescoringGateTests {

    private let threshold = 0.85

    private func update(
        _ text: String,
        isFinal: Bool = true,
        alternatives: [String] = [],
        confidence: Double? = nil
    ) -> TranscriptUpdate {
        TranscriptUpdate(text: text, range: nil, isFinal: isFinal, alternatives: alternatives, confidence: confidence)
    }

    @Test("Volatile updates never rescore")
    func volatileNeverRescores() {
        let u = update(" del", isFinal: false, alternatives: [" del", " dell"], confidence: 0.3)
        #expect(!RescoringGate.needsRescoring(u, threshold: threshold))
    }

    @Test("High confidence passes through even with distinct alternatives")
    func highConfidencePassesThrough() {
        let u = update(" deli", alternatives: [" deli", " daily"], confidence: 0.95)
        #expect(!RescoringGate.needsRescoring(u, threshold: threshold))
    }

    @Test("Confidence exactly at the threshold passes through")
    func thresholdBoundaryPassesThrough() {
        let u = update(" deli", alternatives: [" deli", " daily"], confidence: 0.85)
        #expect(!RescoringGate.needsRescoring(u, threshold: threshold))
    }

    @Test("Missing confidence passes through — no signal, never rescore blindly")
    func nilConfidencePassesThrough() {
        let u = update(" deli", alternatives: [" deli", " daily"], confidence: nil)
        #expect(!RescoringGate.needsRescoring(u, threshold: threshold))
    }

    @Test("No alternatives (or only the primary echo) passes through — nothing to choose")
    func tooFewAlternativesPassesThrough() {
        let none = update(" deli", alternatives: [], confidence: 0.4)
        let echoOnly = update(" deli", alternatives: [" deli"], confidence: 0.4)
        #expect(!RescoringGate.needsRescoring(none, threshold: threshold))
        #expect(!RescoringGate.needsRescoring(echoOnly, threshold: threshold))
    }

    @Test("Near-identical alternatives (punctuation/casing variants) pass through")
    func nearIdenticalAlternativesPassThrough() {
        // The C0 spike's real output for ' town, and': variants differ only in
        // punctuation and capitalization — no lexical choice for a model to make.
        let u = update(
            " town, and",
            alternatives: [" town, and", " town and", " town, And"],
            confidence: 0.76
        )
        #expect(!RescoringGate.needsRescoring(u, threshold: threshold))
    }

    @Test("Low confidence with lexically distinct alternatives rescores")
    func ambiguousSegmentRescores() {
        let u = update(
            " today.",
            alternatives: [" today.", " today,", " day."],
            confidence: 0.76
        )
        #expect(RescoringGate.needsRescoring(u, threshold: threshold))
    }

    @Test("lexicallyEquivalent treats punctuation/casing variants as the same word sequence")
    func lexicallyEquivalentIgnoresPunctuationAndCase() {
        #expect(RescoringGate.lexicallyEquivalent(" man.", " man,"))
        #expect(RescoringGate.lexicallyEquivalent(" saying them.", " saying them,"))
        #expect(RescoringGate.lexicallyEquivalent(" Deli.", " deli"))
        #expect(!RescoringGate.lexicallyEquivalent(" gonna", " going"))
        #expect(!RescoringGate.lexicallyEquivalent(" gotta", " got"))
        #expect(!RescoringGate.lexicallyEquivalent(" man.", " man, you"))
    }

    @Test("Lexical distinction is judged after normalization, not raw string inequality")
    func normalizationJudgesDistinction() {
        // "Deli." vs "deli" — same word; must NOT rescore.
        let sameWord = update(" Deli.", alternatives: [" Deli.", " deli"], confidence: 0.5)
        #expect(!RescoringGate.needsRescoring(sameWord, threshold: threshold))
        // "deli" vs "daily" — different words; must rescore.
        let differentWord = update(" deli", alternatives: [" deli", " daily"], confidence: 0.5)
        #expect(RescoringGate.needsRescoring(differentWord, threshold: threshold))
    }
}
