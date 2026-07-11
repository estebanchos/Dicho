import Foundation
import Testing
@testable import Dicho

/// M12.4 scorer tests — pure logic, run in the normal gate (no live calls).
@Suite("EvalScoring")
struct EvalScoringTests {

    // MARK: - No deviations

    @Test("Identical texts produce zero deviations")
    func identicalTextsAreClean() {
        let text = "The meeting is on Thursday. I'll send the notes to Miguel."
        #expect(EvalScorer.score(expected: text, actual: text).isEmpty)
    }

    // MARK: - Minor classification

    @Test("Casing-only difference is a minor casing deviation")
    func casingIsMinor() {
        let deviations = EvalScorer.score(
            expected: "The meeting is on Thursday.",
            actual: "the meeting is on thursday."
        )
        #expect(!deviations.isEmpty)
        #expect(deviations.allSatisfy { $0.severity == .minor && $0.kind == .casing })
    }

    @Test("Punctuation-only difference is a minor punctuation deviation")
    func punctuationIsMinor() {
        let deviations = EvalScorer.score(
            expected: "We went to the store, and then we left.",
            actual: "We went to the store and then we left"
        )
        #expect(!deviations.isEmpty)
        #expect(deviations.allSatisfy { $0.severity == .minor && $0.kind == .punctuation })
    }

    @Test("Digit vs spelled number is a minor number-format deviation")
    func numberFormatIsMinor() {
        let deviations = EvalScorer.score(
            expected: "give it thirty years",
            actual: "give it 30 years"
        )
        #expect(deviations.count == 1)
        #expect(deviations[0].kind == .numberFormat)
        #expect(deviations[0].severity == .minor)
    }

    @Test("Ordinal word vs digit ordinal is a minor number-format deviation")
    func ordinalFormatIsMinor() {
        let deviations = EvalScorer.score(
            expected: "the first year",
            actual: "the 1st year"
        )
        #expect(deviations.count == 1)
        #expect(deviations[0].kind == .numberFormat)
        #expect(deviations[0].severity == .minor)
    }

    @Test("Multi-word spelled number matches its digit form")
    func multiWordNumberMatchesDigits() {
        let deviations = EvalScorer.score(
            expected: "you've got one thousand seventy dollars",
            actual: "you've got 1070 dollars"
        )
        #expect(deviations.allSatisfy { $0.severity == .minor })
        #expect(deviations.contains { $0.kind == .numberFormat })
    }

    @Test("Article absorbed into a number run: 'a thousand' matches '1000'")
    func articleAbsorbedIntoNumberRun() {
        let deviations = EvalScorer.score(
            expected: "you put in a thousand dollars",
            actual: "you put in 1000 dollars"
        )
        #expect(deviations.allSatisfy { $0.severity == .minor })
    }

    @Test("Percent sign matches the spoken word percent")
    func percentSignMatchesWord() {
        let deviations = EvalScorer.score(
            expected: "an account at seven percent interest",
            actual: "an account at 7% interest"
        )
        #expect(deviations.allSatisfy { $0.severity == .minor })
    }

    @Test("Double spaces and leading whitespace are minor whitespace deviations")
    func whitespaceIsMinor() {
        let deviations = EvalScorer.score(
            expected: "Hello there friend.",
            actual: " Hello  there friend."
        )
        #expect(deviations.contains { $0.kind == .whitespace && $0.severity == .minor })
        #expect(deviations.allSatisfy { $0.severity == .minor })
    }

    // MARK: - Major classification

    @Test("A changed content word is a major substitution")
    func substitutionIsMajor() {
        let deviations = EvalScorer.score(
            expected: "take the bus to town",
            actual: "take the boss to town"
        )
        #expect(deviations.count == 1)
        #expect(deviations[0].kind == .substitution)
        #expect(deviations[0].severity == .major)
        #expect(deviations[0].expected == "bus")
        #expect(deviations[0].actual == "boss")
    }

    @Test("A missing content word is a major deletion")
    func deletionIsMajor() {
        let deviations = EvalScorer.score(
            expected: "she saved every dime she earned",
            actual: "she saved every she earned"
        )
        #expect(deviations.count == 1)
        #expect(deviations[0].kind == .deletion)
        #expect(deviations[0].expected == "dime")
    }

    @Test("An added content word is a major insertion")
    func insertionIsMajor() {
        let deviations = EvalScorer.score(
            expected: "we drove to the coast",
            actual: "we drove far to the coast"
        )
        #expect(deviations.count == 1)
        #expect(deviations[0].kind == .insertion)
        #expect(deviations[0].actual == "far")
    }

    @Test("A leftover filler word is a major filler-residue deviation")
    func fillerResidueIsMajor() {
        let deviations = EvalScorer.score(
            expected: "so I was thinking we should repaint",
            actual: "um so I was thinking we should uh repaint"
        )
        #expect(deviations.count == 2)
        #expect(deviations.allSatisfy { $0.kind == .fillerResidue && $0.severity == .major })
    }

    @Test("Empty actual output yields a deletion per expected word")
    func emptyActualIsTotalLoss() {
        let deviations = EvalScorer.score(expected: "red green blue", actual: "")
        #expect(deviations.count == 3)
        #expect(deviations.allSatisfy { $0.kind == .deletion && $0.severity == .major })
    }

    @Test("Adjacent cardinal words merge into one number unit (documented quirk)")
    func adjacentCardinalsMergeIntoOneUnit() {
        // "one two three" collapses to a single unit — the price of making
        // "one thousand seventy" match "1070". Fixture scripts must not rely
        // on counting sequences or digit-by-digit phone numbers.
        let deviations = EvalScorer.score(expected: "one two three", actual: "")
        #expect(deviations.count == 1)
        #expect(deviations[0].kind == .deletion)
    }

    @Test("Repeated words align without spurious deviations")
    func repeatedWordsAlign() {
        let text = "very very long day after a very long night"
        #expect(EvalScorer.score(expected: text, actual: text).isEmpty)
    }

    // MARK: - Assertions

    @Test("mustContain miss is a major assertion failure")
    func mustContainMissIsMajor() {
        let deviations = EvalScorer.score(
            expected: "The meeting is on Thursday.",
            actual: "The meeting is on Thursday.",
            mustContain: ["Friday"]
        )
        #expect(deviations.count == 1)
        #expect(deviations[0].kind == .assertionFailure)
        #expect(deviations[0].expected == "Friday")
    }

    @Test("mustNotContain hit is a major assertion failure")
    func mustNotContainHitIsMajor() {
        let deviations = EvalScorer.score(
            expected: "The meeting is on Thursday.",
            actual: "The meeting is on Tuesday, no wait, Thursday.",
            mustNotContain: ["Tuesday", "no wait"]
        )
        #expect(deviations.count(where: { $0.kind == .assertionFailure }) == 2)
    }

    @Test("Single-word needles are word-boundary matched, not substring matched")
    func singleWordNeedlesRespectBoundaries() {
        // "um" must not match inside "umbrella"; "daily" must not match "dailyish".
        let clean = EvalScorer.score(
            expected: "I forgot my umbrella today.",
            actual: "I forgot my umbrella today.",
            mustNotContain: ["um"]
        )
        #expect(clean.isEmpty)

        let hit = EvalScorer.score(
            expected: "so I left",
            actual: "um so I left",
            mustNotContain: ["um"]
        )
        #expect(hit.contains { $0.kind == .assertionFailure })
    }

    @Test("An = prefix makes a needle surface-form-only (no normalization)")
    func rawPrefixDisablesNormalization() {
        // "=1st" must fire only on the literal digit ordinal, never on "first".
        let wordForm = EvalScorer.score(
            expected: "the first year",
            actual: "the first year",
            mustNotContain: ["=1st"]
        )
        #expect(wordForm.isEmpty)

        let digitForm = EvalScorer.score(
            expected: "the first year",
            actual: "the 1st year",
            mustNotContain: ["=1st"]
        )
        #expect(digitForm.contains { $0.kind == .assertionFailure })

        // "=empty." requires the literal period to survive.
        let periodKept = EvalScorer.score(
            expected: "It was empty. Everyone left.",
            actual: "It was empty. Everyone left.",
            mustContain: ["=empty."]
        )
        #expect(periodKept.isEmpty)

        let periodLost = EvalScorer.score(
            expected: "It was empty. Everyone left.",
            actual: "It was empty, everyone left.",
            mustContain: ["=empty."]
        )
        #expect(periodLost.contains { $0.kind == .assertionFailure })
    }

    @Test("Assertions also match number-normalized forms")
    func assertionsMatchNormalizedNumbers() {
        // "seven percent" must be satisfied by "7%".
        let contain = EvalScorer.score(
            expected: "an account at seven percent",
            actual: "an account at 7%",
            mustContain: ["seven percent"]
        )
        #expect(!contain.contains { $0.kind == .assertionFailure })

        // "twenty" must be flagged even when it appears as "20".
        let notContain = EvalScorer.score(
            expected: "keep it thirty years",
            actual: "keep it 20 years",
            mustNotContain: ["twenty"]
        )
        #expect(notContain.contains { $0.kind == .assertionFailure })
    }

    // MARK: - Layer attribution

    private static let segments = [
        TranscriptUpdate(
            text: " take the boss",
            range: nil,
            isFinal: true,
            alternatives: [" take the boss", " take the bus"],
            confidence: 0.55
        ),
        TranscriptUpdate(
            text: " to town",
            range: nil,
            isFinal: true,
            alternatives: [" to town"],
            confidence: 0.98
        ),
    ]

    @Test("Truth surviving to the rescored text attributes to cleanup-introduced")
    func truthInRescoredIsCleanupIntroduced() {
        let intermediates = EvalIntermediates(
            rawTopJoin: "take the bus to town",
            rescoredText: "take the bus to town",
            segments: Self.segments
        )
        let deviations = EvalScorer.score(
            expected: "take the bus to town",
            actual: "take the boss to town",
            intermediates: intermediates
        )
        #expect(deviations.count == 1)
        #expect(deviations[0].layer == .cleanupIntroduced)
    }

    @Test("Truth present only in the raw top join attributes to rescoring-missed")
    func truthOnlyInRawIsRescoringMissed() {
        let intermediates = EvalIntermediates(
            rawTopJoin: "take the bus to town",
            rescoredText: "take the boss to town",
            segments: Self.segments
        )
        let deviations = EvalScorer.score(
            expected: "take the bus to town",
            actual: "take the boss to town",
            intermediates: intermediates
        )
        #expect(deviations[0].layer == .rescoringMissed)
    }

    @Test("Truth present only among n-best candidates attributes to rescoring-missed")
    func truthOnlyInCandidatesIsRescoringMissed() {
        let intermediates = EvalIntermediates(
            rawTopJoin: "take the boss to town",
            rescoredText: "take the boss to town",
            segments: Self.segments
        )
        let deviations = EvalScorer.score(
            expected: "take the bus to town",
            actual: "take the boss to town",
            intermediates: intermediates
        )
        #expect(deviations[0].layer == .rescoringMissed)
    }

    @Test("Truth absent everywhere attributes to asr-ceiling")
    func truthNowhereIsCeiling() {
        let intermediates = EvalIntermediates(
            rawTopJoin: "take the boss to town",
            rescoredText: "take the boss to town",
            segments: [Self.segments[1]]
        )
        let deviations = EvalScorer.score(
            expected: "take the bus to town",
            actual: "take the boss to town",
            intermediates: intermediates
        )
        #expect(deviations[0].layer == .asrCeiling)
    }

    @Test("Offending text present in the rescored input attributes to cleanup-missed")
    func offendingTextInRescoredIsCleanupMissed() {
        let intermediates = EvalIntermediates(
            rawTopJoin: "the meeting is on Tuesday no wait Thursday",
            rescoredText: "the meeting is on Tuesday no wait Thursday",
            segments: []
        )
        let deviations = EvalScorer.score(
            expected: "The meeting is on Thursday.",
            actual: "The meeting is on Tuesday, no wait, Thursday.",
            mustNotContain: ["Tuesday", "no wait"],
            intermediates: intermediates
        )
        let assertionFailures = deviations.filter { $0.kind == .assertionFailure }
        #expect(assertionFailures.count == 2)
        #expect(assertionFailures.allSatisfy { $0.layer == .cleanupMissed })
    }

    @Test("Offending text absent from the rescored input attributes to cleanup-introduced")
    func offendingTextNotInRescoredIsCleanupIntroduced() {
        let intermediates = EvalIntermediates(
            rawTopJoin: "we drove to the coast",
            rescoredText: "we drove to the coast",
            segments: []
        )
        let deviations = EvalScorer.score(
            expected: "we drove to the coast",
            actual: "we drove far to the coast",
            intermediates: intermediates
        )
        #expect(deviations.count == 1)
        #expect(deviations[0].kind == .insertion)
        #expect(deviations[0].layer == .cleanupIntroduced)
    }
}
