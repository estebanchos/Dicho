import Foundation
import Testing
@testable import Dicho

/// M17.1 tests for `AsrABScoring` — pure logic, hand-built `TranscriptUpdate`s
/// and inline JSON literals only. No Speech/AVFoundation imports; this suite
/// runs in the normal gate (unlike the live-model `AsrABRun` spike).
@Suite("AsrABScoringTests")
struct AsrABScoringTests {

    // MARK: - rawTopJoin

    @Test("Final segments are trimmed and joined with a single space")
    func rawTopJoinTrimsAndJoins() {
        let segments = [
            TranscriptUpdate(text: "  hello there ", range: nil, isFinal: true),
            TranscriptUpdate(text: " general kenobi", range: nil, isFinal: true),
        ]
        #expect(AsrABScoring.rawTopJoin(of: segments) == "hello there general kenobi")
    }

    @Test("Volatile segments are dropped even when they carry text")
    func rawTopJoinDropsVolatiles() {
        let segments = [
            TranscriptUpdate(text: "hello", range: nil, isFinal: true),
            TranscriptUpdate(text: " hello there entirely wrong guess", range: nil, isFinal: false),
            TranscriptUpdate(text: "there", range: nil, isFinal: true),
        ]
        #expect(AsrABScoring.rawTopJoin(of: segments) == "hello there")
    }

    @Test("Empty-after-trim segments are dropped, not joined as blank tokens")
    func rawTopJoinDropsEmptySegments() {
        let segments = [
            TranscriptUpdate(text: "hello", range: nil, isFinal: true),
            TranscriptUpdate(text: "   ", range: nil, isFinal: true),
            TranscriptUpdate(text: "there", range: nil, isFinal: true),
        ]
        #expect(AsrABScoring.rawTopJoin(of: segments) == "hello there")
    }

    @Test("No final segments yields an empty string")
    func rawTopJoinEmptyWhenNoFinals() {
        let segments = [TranscriptUpdate(text: "hello", range: nil, isFinal: false)]
        #expect(AsrABScoring.rawTopJoin(of: segments) == "")
    }

    // MARK: - score (spoken-reference partition)

    @Test("A content substitution lands in contentMajors")
    func scorePartitionsSubstitutionAsMajor() {
        let result = AsrABScoring.score(spoken: "take the bus to town", rawTopJoin: "take the boss to town")
        #expect(result.contentMajors.count == 1)
        #expect(result.contentMajors[0].kind == .substitution)
        #expect(result.minors.isEmpty)
        #expect(result.fillerDrops.isEmpty)
    }

    @Test("A casing-only difference lands in minors, not contentMajors")
    func scorePartitionsCasingAsMinor() {
        let result = AsrABScoring.score(spoken: "The meeting is on Thursday.", rawTopJoin: "the meeting is on thursday.")
        #expect(result.contentMajors.isEmpty)
        #expect(!result.minors.isEmpty)
        #expect(result.minors.allSatisfy { $0.severity == .minor })
    }

    @Test("A deleted filler lands in fillerDrops, not contentMajors")
    func scorePartitionsFillerDeletionAsFillerDrop() {
        // "Um" capitalized on purpose: the lexicon check must run on the
        // EvalTokenizer-normalized form, not the surface.
        let result = AsrABScoring.score(spoken: "Um so I was thinking, uh, we should repaint", rawTopJoin: "so I was thinking, we should repaint")
        #expect(result.fillerDrops.count == 2)
        #expect(result.fillerDrops.allSatisfy { $0.kind == .deletion })
        #expect(result.contentMajors.isEmpty)
    }

    @Test("A non-filler deletion is still a content major")
    func scorePartitionsRealDeletionAsMajor() {
        let result = AsrABScoring.score(spoken: "she saved every dime she earned", rawTopJoin: "she saved every she earned")
        #expect(result.contentMajors.count == 1)
        #expect(result.contentMajors[0].kind == .deletion)
        #expect(result.fillerDrops.isEmpty)
    }

    @Test("An inserted filler keeps EvalScorer's fillerResidue classification (major)")
    func scorePartitionsFillerInsertionAsMajor() {
        let result = AsrABScoring.score(spoken: "so I left", rawTopJoin: "um so I left")
        #expect(result.contentMajors.count == 1)
        #expect(result.contentMajors[0].kind == .fillerResidue)
        #expect(result.fillerDrops.isEmpty)
    }

    @Test("A diacritic-only substitution lands in minors, not contentMajors")
    func scorePartitionsDiacriticOnlySubstitutionAsMinor() {
        let result = AsrABScoring.score(spoken: "meet me at the cafe on Main", rawTopJoin: "meet me at the café on Main")
        #expect(result.contentMajors.isEmpty)
        #expect(result.minors.count == 1)
        #expect(result.minors[0].kind == .substitution)
        #expect(result.fillerDrops.isEmpty)
    }

    @Test("A diacritic-only substitution is minor in the reverse direction too")
    func scorePartitionsDiacriticOnlySubstitutionReverse() {
        let result = AsrABScoring.score(spoken: "meet me at the café on Main", rawTopJoin: "meet me at the cafe on Main")
        #expect(result.contentMajors.isEmpty)
        #expect(result.minors.count == 1)
    }

    // MARK: - ceilingItems decoding

    private static let baselineJSON = """
    {
      "results": [
        {
          "fixtureID": "fixture-a",
          "variant": "recorded",
          "repeats": [
            {
              "deviations": [
                {"kind": "substitution", "severity": "major", "expected": "bus", "actual": "boss", "layer": "asr-ceiling"},
                {"kind": "punctuation", "severity": "minor", "expected": "hi,", "actual": "hi"},
                {"kind": "deletion", "severity": "major", "expected": "dollars", "layer": "asr-ceiling"},
                {"kind": "substitution", "severity": "major", "expected": "bus", "actual": "boss", "layer": "asr-ceiling"},
                {"kind": "assertion-failure", "severity": "major", "expected": "missed", "layer": "rescoring-missed"}
              ]
            },
            {
              "deviations": [
                {"kind": "substitution", "severity": "major", "expected": "repeat1-only", "actual": "x", "layer": "asr-ceiling"}
              ]
            }
          ]
        },
        {
          "fixtureID": "fixture-a",
          "variant": "recorded:maria",
          "repeats": [
            {
              "deviations": [
                {"kind": "substitution", "severity": "major", "expected": "maria-only", "actual": "y", "layer": "asr-ceiling"}
              ]
            }
          ]
        }
      ]
    }
    """

    @Test("ceilingItems filters variant, repeat 0 only, layer, and de-dups preserving order")
    func ceilingItemsDecodesAndFilters() throws {
        let items = try AsrABScoring.ceilingItems(fromBaselineJSON: Data(Self.baselineJSON.utf8))

        // Dedup collapses the two identical bus/boss entries into one, order preserved.
        #expect(items == [
            AsrABScoring.CeilingItem(fixtureID: "fixture-a", expected: "bus", actual: "boss"),
            AsrABScoring.CeilingItem(fixtureID: "fixture-a", expected: "dollars", actual: nil),
        ])
        // repeat-1-only and maria-only and non-asr-ceiling entries never appear.
        #expect(!items.contains { $0.expected == "repeat1-only" })
        #expect(!items.contains { $0.expected == "maria-only" })
        #expect(!items.contains { $0.expected == "missed" })
        #expect(!items.contains { $0.expected == "hi," })
    }

    // MARK: - recovered matcher

    @Test("Exact single-word match recovers")
    func recoveredExactHit() {
        let item = AsrABScoring.CeilingItem(fixtureID: "f", expected: "bus", actual: "boss")
        #expect(AsrABScoring.recovered(item, inRawTopJoin: "take the bus to town") == true)
    }

    @Test("Case and punctuation differences still recover")
    func recoveredCaseAndPunctuationInsensitive() {
        let item = AsrABScoring.CeilingItem(fixtureID: "f", expected: "JSON", actual: "Jason")
        #expect(AsrABScoring.recovered(item, inRawTopJoin: "send me the json, please") == true)
    }

    @Test("Multi-word contiguous match recovers")
    func recoveredMultiWordContiguous() {
        let item = AsrABScoring.CeilingItem(fixtureID: "f", expected: "principal explained", actual: nil)
        #expect(AsrABScoring.recovered(item, inRawTopJoin: "the principal explained the new rule") == true)
    }

    @Test("Non-contiguous word order does not recover")
    func recoveredNonContiguousMiss() {
        let item = AsrABScoring.CeilingItem(fixtureID: "f", expected: "day old", actual: "old")
        #expect(AsrABScoring.recovered(item, inRawTopJoin: "the bread was old, from that day") == false)
    }

    @Test("Absent truth does not recover")
    func recoveredAbsentMiss() {
        let item = AsrABScoring.CeilingItem(fixtureID: "f", expected: "vice president", actual: nil)
        #expect(AsrABScoring.recovered(item, inRawTopJoin: "the meeting went fine") == false)
    }

    @Test("Nil expected is unmatchable, not a miss")
    func recoveredNilExpectedIsNil() {
        let item = AsrABScoring.CeilingItem(fixtureID: "f", expected: nil, actual: "screw")
        #expect(AsrABScoring.recovered(item, inRawTopJoin: "anything at all") == nil)
    }

    @Test("Accented truth recovers from an unaccented join")
    func recoveredDiacriticTruthMatchesPlainJoin() {
        let item = AsrABScoring.CeilingItem(fixtureID: "f", expected: "café", actual: "coffee")
        #expect(AsrABScoring.recovered(item, inRawTopJoin: "the cafe on main street") == true)
    }

    @Test("Plain truth recovers from an accented join")
    func recoveredPlainTruthMatchesDiacriticJoin() {
        let item = AsrABScoring.CeilingItem(fixtureID: "f", expected: "cafe", actual: "coffee")
        #expect(AsrABScoring.recovered(item, inRawTopJoin: "the café on main street") == true)
    }

    @Test("Expected that normalizes to nothing (pure punctuation) is unmatchable")
    func recoveredPunctuationOnlyExpectedIsNil() {
        let item = AsrABScoring.CeilingItem(fixtureID: "f", expected: "--", actual: nil)
        #expect(AsrABScoring.recovered(item, inRawTopJoin: "anything at all") == nil)
    }

    // MARK: - ceilingRecovery

    @Test("ceilingRecovery counts total, recovered, and unmatchable for one fixture")
    func ceilingRecoveryCounts() {
        let items = [
            AsrABScoring.CeilingItem(fixtureID: "f1", expected: "bus", actual: "boss"),
            AsrABScoring.CeilingItem(fixtureID: "f1", expected: "dime", actual: "time"),
            AsrABScoring.CeilingItem(fixtureID: "f1", expected: nil, actual: "screw"),
            AsrABScoring.CeilingItem(fixtureID: "f2", expected: "unrelated", actual: nil),
        ]
        let recovery = AsrABScoring.ceilingRecovery(items: items, fixtureID: "f1", rawTopJoin: "take the bus to town")
        #expect(recovery.total == 3)
        #expect(recovery.recovered == 1) // "bus" recovers, "dime" is absent, nil-expected is unmatchable.
        #expect(recovery.unmatchable == 1)
    }

    @Test("ceilingRecovery ignores items for other fixtures")
    func ceilingRecoveryFiltersByFixture() {
        let items = [AsrABScoring.CeilingItem(fixtureID: "other", expected: "bus", actual: "boss")]
        let recovery = AsrABScoring.ceilingRecovery(items: items, fixtureID: "f1", rawTopJoin: "take the bus to town")
        #expect(recovery == AsrABScoring.CeilingRecovery(total: 0, recovered: 0, unmatchable: 0))
    }

    // MARK: - confidenceStats

    @Test("Empty input yields count 0 and nil minimum/median")
    func confidenceStatsEmpty() {
        let stats = AsrABScoring.confidenceStats(of: [])
        #expect(stats.count == 0)
        #expect(stats.minimum == nil)
        #expect(stats.median == nil)
        #expect(stats.deciles == Array(repeating: 0, count: 10))
    }

    @Test("Odd count takes the middle value as median")
    func confidenceStatsOddMedian() {
        let segments = [0.3, 0.9, 0.5].map {
            TranscriptUpdate(text: "x", range: nil, isFinal: true, confidence: $0)
        }
        let stats = AsrABScoring.confidenceStats(of: segments)
        #expect(stats.count == 3)
        #expect(stats.minimum == 0.3)
        #expect(stats.median == 0.5)
    }

    @Test("Even count averages the middle two values")
    func confidenceStatsEvenMedian() {
        let segments = [0.2, 0.8].map {
            TranscriptUpdate(text: "x", range: nil, isFinal: true, confidence: $0)
        }
        let stats = AsrABScoring.confidenceStats(of: segments)
        #expect(stats.count == 2)
        #expect(stats.median == 0.5)
    }

    @Test("Deciles bucket [0.0,0.1)...[0.9,1.0] with 1.0 landing in the last bucket")
    func confidenceStatsDecileBucketing() {
        let confidences = [0.05, 0.15, 0.55, 0.89, 0.99, 1.0]
        let segments = confidences.map {
            TranscriptUpdate(text: "x", range: nil, isFinal: true, confidence: $0)
        }
        let stats = AsrABScoring.confidenceStats(of: segments)
        var expected = Array(repeating: 0, count: 10)
        expected[0] = 1 // 0.05
        expected[1] = 1 // 0.15
        expected[5] = 1 // 0.55
        expected[8] = 1 // 0.89
        expected[9] = 2 // 0.99 and 1.0 both land in the last bucket
        #expect(stats.deciles == expected)
    }

    @Test("Volatile segments and finals without confidence are ignored")
    func confidenceStatsIgnoresVolatilesAndMissingConfidence() {
        let segments = [
            TranscriptUpdate(text: "a", range: nil, isFinal: true, confidence: 0.4),
            TranscriptUpdate(text: "b", range: nil, isFinal: false, confidence: 0.99),
            TranscriptUpdate(text: "c", range: nil, isFinal: true, confidence: nil),
        ]
        let stats = AsrABScoring.confidenceStats(of: segments)
        #expect(stats.count == 1)
        #expect(stats.minimum == 0.4)
    }

    // MARK: - gateFirings

    @Test("Confidence exactly at the threshold does not fire (strict less-than in RescoringGate)")
    func gateFiringsBoundaryAtThresholdDoesNotFire() {
        let segment = TranscriptUpdate(
            text: "x",
            range: nil,
            isFinal: true,
            alternatives: ["one thing", "another thing"],
            confidence: Constants.rescoringConfidenceThreshold
        )
        #expect(AsrABScoring.gateFirings(in: [segment]) == 0)
    }

    @Test("Confidence just below the threshold with distinct alternatives fires")
    func gateFiringsBelowThresholdFires() {
        let segment = TranscriptUpdate(
            text: "x",
            range: nil,
            isFinal: true,
            alternatives: ["one thing", "another thing"],
            confidence: Constants.rescoringConfidenceThreshold - 0.01
        )
        #expect(AsrABScoring.gateFirings(in: [segment]) == 1)
    }

    @Test("Counts firings across multiple segments")
    func gateFiringsCountsAcrossSegments() {
        let firing = TranscriptUpdate(
            text: "x", range: nil, isFinal: true,
            alternatives: ["alpha", "beta"], confidence: 0.1
        )
        let passthrough = TranscriptUpdate(
            text: "y", range: nil, isFinal: true,
            alternatives: ["alpha", "beta"], confidence: 0.95
        )
        #expect(AsrABScoring.gateFirings(in: [firing, passthrough, firing]) == 2)
    }

    // MARK: - summaryMarkdown

    private static func sampleReport() -> AsrABScoring.AsrABReport {
        func record(fixtureID: String, arm: String, repeatIndex: Int, majors: Int, recovered: Int, total: Int, variant: String = "recorded") -> AsrABScoring.AsrABFixtureArmRecord {
            AsrABScoring.AsrABFixtureArmRecord(
                fixtureID: fixtureID,
                variant: variant,
                armName: arm,
                repeatIndex: repeatIndex,
                rawTopJoin: "some text",
                contentMajorCount: majors,
                minorCount: 0,
                fillerDropCount: 2,
                contentMajors: [],
                minors: [],
                fillerDrops: [],
                ceiling: AsrABScoring.CeilingRecovery(total: total, recovered: recovered, unmatchable: 0),
                confidence: AsrABScoring.ConfidenceStats(count: 1, minimum: 0.5, median: 0.5, deciles: Array(repeating: 0, count: 10)),
                gateFirings: 0,
                segmentCount: 1,
                alternativesPerFinal: [1],
                stopToLastFinalSeconds: 1.0
            )
        }
        return AsrABScoring.AsrABReport(
            label: "smoke",
            timestamp: "20260716-000000",
            gitCommit: "abc1234",
            arms: ["baseline", "dictation"],
            records: [
                record(fixtureID: "fixture-b", arm: "dictation", repeatIndex: 0, majors: 1, recovered: 0, total: 1),
                record(fixtureID: "fixture-a", arm: "baseline", repeatIndex: 0, majors: 2, recovered: 1, total: 2),
            ],
            skipped: ["fixture-c"]
        )
    }

    @Test("summaryMarkdown mentions arm names and fixture ids")
    func summaryMarkdownContainsArmsAndFixtures() {
        let markdown = AsrABScoring.summaryMarkdown(for: Self.sampleReport())
        #expect(markdown.contains("baseline"))
        #expect(markdown.contains("dictation"))
        #expect(markdown.contains("fixture-a"))
        #expect(markdown.contains("fixture-b"))
        #expect(markdown.contains("fixture-c")) // skipped section
    }

    @Test("summaryMarkdown marks the recorded variant as gating in its aggregate heading")
    func summaryMarkdownMarksRecordedAsGating() {
        let markdown = AsrABScoring.summaryMarkdown(for: Self.sampleReport())
        #expect(markdown.contains("### recorded (gating)"))
    }

    @Test("summaryMarkdown per-fixture table carries a variant column")
    func summaryMarkdownPerFixtureHasVariantColumn() {
        let markdown = AsrABScoring.summaryMarkdown(for: Self.sampleReport())
        #expect(markdown.contains("| fixture | variant | arm | repeat |"))
        #expect(markdown.contains("| fixture-a | recorded | baseline |"))
    }

    @Test("summaryMarkdown splits per-arm aggregates by variant, recorded first, sums independent")
    func summaryMarkdownSplitsAggregatesByVariant() {
        func record(fixtureID: String, arm: String, variant: String, majors: Int) -> AsrABScoring.AsrABFixtureArmRecord {
            AsrABScoring.AsrABFixtureArmRecord(
                fixtureID: fixtureID,
                variant: variant,
                armName: arm,
                repeatIndex: 0,
                rawTopJoin: "some text",
                contentMajorCount: majors,
                minorCount: 0,
                fillerDropCount: 0,
                contentMajors: [],
                minors: [],
                fillerDrops: [],
                ceiling: AsrABScoring.CeilingRecovery(total: 0, recovered: 0, unmatchable: 0),
                confidence: AsrABScoring.ConfidenceStats(count: 1, minimum: 0.5, median: 0.5, deciles: Array(repeating: 0, count: 10)),
                gateFirings: 0,
                segmentCount: 1,
                alternativesPerFinal: [1],
                stopToLastFinalSeconds: 1.0
            )
        }
        let report = AsrABScoring.AsrABReport(
            label: "split",
            timestamp: "20260717-000000",
            gitCommit: "abc1234",
            arms: ["baseline"],
            records: [
                // Canary listed FIRST in the input to prove ordering is
                // imposed by the renderer, not inherited from the caller.
                record(fixtureID: "f", arm: "baseline", variant: "recorded:maria", majors: 5),
                record(fixtureID: "f", arm: "baseline", variant: "recorded", majors: 2),
            ],
            skipped: []
        )
        let markdown = AsrABScoring.summaryMarkdown(for: report)

        let gatingHeading = "### recorded (gating)"
        let canaryHeading = "### recorded:maria (canary)"
        let gatingRange = markdown.range(of: gatingHeading)
        let canaryRange = markdown.range(of: canaryHeading)
        #expect(gatingRange != nil)
        #expect(canaryRange != nil)
        guard let gatingRange, let canaryRange else { return }
        // Gating section renders before the canary section.
        #expect(gatingRange.lowerBound < canaryRange.lowerBound)

        // Independent sums: the gating section's baseline row shows 2 majors,
        // the canary section's shows 5 — never a blended 7.
        let gatingSection = String(markdown[gatingRange.upperBound..<canaryRange.lowerBound])
        let canarySection = String(markdown[canaryRange.upperBound...])
        #expect(gatingSection.contains("| baseline | 2 |"))
        #expect(canarySection.contains("| baseline | 5 |"))
        #expect(!markdown.contains("| baseline | 7 |"))
    }

    @Test("summaryMarkdown carries the filler-drops column in both tables")
    func summaryMarkdownContainsFillerDropsColumn() {
        let markdown = AsrABScoring.summaryMarkdown(for: Self.sampleReport())
        // Column header appears in the per-arm aggregate AND per-fixture tables.
        let headerOccurrences = markdown.components(separatedBy: "filler drops").count - 1
        #expect(headerOccurrences >= 2)
        // Each sample record carries fillerDropCount 2; the per-arm rows (one
        // record per arm) must show the aggregate 2.
        #expect(markdown.contains("| 2 |"))
    }

    @Test("summaryMarkdown is deterministic regardless of input record order")
    func summaryMarkdownIsDeterministic() {
        let report = Self.sampleReport()
        var shuffled = report
        shuffled = AsrABScoring.AsrABReport(
            label: report.label,
            timestamp: report.timestamp,
            gitCommit: report.gitCommit,
            arms: report.arms,
            records: Array(report.records.reversed()),
            skipped: report.skipped
        )
        #expect(AsrABScoring.summaryMarkdown(for: report) == AsrABScoring.summaryMarkdown(for: shuffled))
    }
}
