import Foundation
@testable import Dicho

/// M17.1 ASR A/B eval scoring helpers (`Documentation/asr_ab_plan.md` §3.3).
///
/// Pure, gate-tested logic that turns a `TranscriptUpdate` stream and the
/// M12 baseline report into the metrics the Phase A decision gate needs:
/// - content-major / minor counts against the manifest's **spoken** text
///   (the ASR-layer reference — fillers and self-corrections SHOULD be
///   transcribed at this layer, unlike the cleaned-text `expected` field);
/// - ceiling-recovery against the `asr-ceiling` majors already recorded in
///   `EvalResults/baseline.json` — the decision-driving metric;
/// - per-segment confidence distribution and would-be `RescoringGate`
///   firings, for gating-parity comparison across arms;
/// - `AsrABReport`/`summaryMarkdown`, a dedicated report shape (NOT
///   `EvalRunReport` — the M12 pipeline schema doesn't fit a spoken-reference,
///   multi-arm comparison).
///
/// No Speech/AVFoundation imports and no live model calls — this file and its
/// tests run in the normal gate. The live-model runner (`AsrABRun`, a later
/// task) is the only env-gated, non-gate-run piece of M17.1.
enum AsrABScoring {

    // MARK: - Raw join

    /// Trim-and-join rule for a segment stream's finals, matching `EvalRun`
    /// exactly (`DichoTests/Eval/EvalRunTests.swift` lines 148-152): keep only
    /// `isFinal == true` segments, trim each with `.whitespacesAndNewlines`,
    /// drop any that become empty, join the rest with a single space.
    static func rawTopJoin(of segments: [TranscriptUpdate]) -> String {
        segments
            .filter(\.isFinal)
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Spoken-reference score

    /// `EvalScorer.score(expected: spoken, actual: rawTopJoin)` output,
    /// partitioned into content majors (the headline ASR metric) and minors
    /// (casing/punctuation/whitespace/number-format — reported separately
    /// since the two model families predictably differ here).
    struct ArmScore: Codable, Equatable {
        let contentMajors: [EvalDeviation]
        let minors: [EvalDeviation]
    }

    /// Scores an arm's raw top-hypothesis join against the manifest's
    /// **spoken** field. No `mustContain`/`mustNotContain` and no
    /// `EvalIntermediates` — this is an ASR-layer-only comparison, not a
    /// pipeline-layer attribution.
    static func score(spoken: String, rawTopJoin: String) -> ArmScore {
        let deviations = EvalScorer.score(expected: spoken, actual: rawTopJoin)
        var contentMajors: [EvalDeviation] = []
        var minors: [EvalDeviation] = []
        for deviation in deviations {
            if deviation.severity == .major {
                contentMajors.append(deviation)
            } else {
                minors.append(deviation)
            }
        }
        return ArmScore(contentMajors: contentMajors, minors: minors)
    }

    // MARK: - Ceiling-recovery matcher

    /// One `asr-ceiling` major pulled out of `EvalResults/baseline.json`:
    /// a truth (`expected`) that SpeechTranscriber's raw output and every
    /// n-best candidate missed entirely, plus what it produced instead
    /// (`actual`, when the baseline deviation carried one).
    struct CeilingItem: Codable, Equatable, Hashable {
        let fixtureID: String
        let expected: String?
        let actual: String?
    }

    /// Decodes only the fields the ceiling-recovery matcher needs from the
    /// M12 report shape — deliberately NOT `EvalRunReport` (that type lives
    /// behind pipeline-only intermediates this task doesn't have, and a
    /// full-schema dependency would break the moment the M12 report grows a
    /// field). Keeps `variant == "recorded"` only (the sole gating variant
    /// per the M12.8 ruling — `recorded:maria` is a reported-only canary and
    /// TTS variants are retired), the FIRST repeat only (index 0 — the
    /// baseline's ceiling class is deterministic across repeats per the M12
    /// harness design, so one repeat is the source of truth), and only
    /// deviations tagged `layer == "asr-ceiling"`. De-duplicates by
    /// (fixtureID, expected, actual), preserving first-seen order — the same
    /// ceiling substitution is typically repeated verbatim across a
    /// fixture's repeats/segments.
    static func ceilingItems(fromBaselineJSON data: Data) throws -> [CeilingItem] {
        let report = try JSONDecoder().decode(BaselineReportShape.self, from: data)
        var items: [CeilingItem] = []
        var seen: Set<CeilingItem> = []
        for result in report.results where result.variant == "recorded" {
            guard let firstRepeat = result.repeats.first else { continue }
            for deviation in firstRepeat.deviations where deviation.layer == "asr-ceiling" {
                let item = CeilingItem(fixtureID: result.fixtureID, expected: deviation.expected, actual: deviation.actual)
                if seen.insert(item).inserted {
                    items.append(item)
                }
            }
        }
        return items
    }

    private struct BaselineReportShape: Decodable {
        let results: [BaselineResultShape]
    }

    private struct BaselineResultShape: Decodable {
        let fixtureID: String
        let variant: String
        let repeats: [BaselineRepeatShape]
    }

    private struct BaselineRepeatShape: Decodable {
        let deviations: [BaselineDeviationShape]
    }

    private struct BaselineDeviationShape: Decodable {
        let kind: String
        let severity: String
        let expected: String?
        let actual: String?
        let layer: String?
    }

    /// `true` when `item.expected`'s normalized token sequence appears as a
    /// CONTIGUOUS subsequence of `join`'s normalized token sequence (reusing
    /// `EvalTokenizer`'s normalization — lowercased, punctuation-stripped,
    /// number-canonicalized — rather than re-implementing it). `nil` when
    /// there is no truth string to search for: `expected` is nil, or it
    /// normalizes to nothing (pure punctuation).
    static func recovered(_ item: CeilingItem, inRawTopJoin join: String) -> Bool? {
        guard let expected = item.expected else { return nil }
        let needle = EvalTokenizer.normalizedSequence(expected)
        guard !needle.isEmpty else { return nil }
        let haystack = EvalTokenizer.normalizedSequence(join)
        return EvalTokenizer.containsSubsequence(haystack, needle)
    }

    /// Per-fixture rollup of `recovered(_:inRawTopJoin:)` over a set of
    /// ceiling items. `unmatchable` items (nil-or-empty truth) count toward
    /// `total` but not `recovered` — they can never contribute to the
    /// ceiling-recovery percentage either way.
    struct CeilingRecovery: Codable, Equatable {
        let total: Int
        let recovered: Int
        let unmatchable: Int
    }

    static func ceilingRecovery(items: [CeilingItem], fixtureID: String, rawTopJoin: String) -> CeilingRecovery {
        let relevant = items.filter { $0.fixtureID == fixtureID }
        var recoveredCount = 0
        var unmatchableCount = 0
        for item in relevant {
            switch recovered(item, inRawTopJoin: rawTopJoin) {
            case .some(true):
                recoveredCount += 1
            case .some(false):
                break
            case .none:
                unmatchableCount += 1
            }
        }
        return CeilingRecovery(total: relevant.count, recovered: recoveredCount, unmatchable: unmatchableCount)
    }

    // MARK: - Confidence stats

    /// Per-arm confidence distribution over FINAL segments with a non-nil
    /// confidence only — the gating-parity signal §3.2 calls for (arm 2's
    /// confidence distribution isn't assumed portable from the 0.70 threshold
    /// field-tuned on SpeechTranscriber). `deciles` is a 10-bucket histogram:
    /// index i covers [i/10, (i+1)/10), except the last bucket is the closed
    /// interval [0.9, 1.0] (1.0 lands there, not in a would-be 11th bucket).
    struct ConfidenceStats: Codable, Equatable {
        let count: Int
        let minimum: Double?
        let median: Double?
        let deciles: [Int]
    }

    static func confidenceStats(of segments: [TranscriptUpdate]) -> ConfidenceStats {
        let confidences = segments.compactMap { segment -> Double? in
            guard segment.isFinal else { return nil }
            return segment.confidence
        }
        guard !confidences.isEmpty else {
            return ConfidenceStats(count: 0, minimum: nil, median: nil, deciles: Array(repeating: 0, count: 10))
        }
        let sorted = confidences.sorted()
        var deciles = Array(repeating: 0, count: 10)
        for confidence in confidences {
            deciles[decileBucket(for: confidence)] += 1
        }
        return ConfidenceStats(count: confidences.count, minimum: sorted.first, median: median(ofSorted: sorted), deciles: deciles)
    }

    private static func decileBucket(for confidence: Double) -> Int {
        min(9, max(0, Int(confidence * 10)))
    }

    /// Average of the middle two for even counts, the middle value for odd
    /// counts. `values` must already be sorted.
    private static func median(ofSorted values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        if values.count.isMultiple(of: 2) {
            return (values[values.count / 2 - 1] + values[values.count / 2]) / 2
        }
        return values[values.count / 2]
    }

    // MARK: - Gate firings

    /// Count of segments that would have fired `RescoringGate.needsRescoring`
    /// at the production threshold — the arm's would-be rescoring load, for
    /// gating-parity comparison (§3.2: alternatives + confidence are required
    /// so any integration outcome keeps `RescoringGate` working).
    static func gateFirings(in segments: [TranscriptUpdate]) -> Int {
        segments.count { RescoringGate.needsRescoring($0, threshold: Constants.rescoringConfidenceThreshold) }
    }

    // MARK: - Report

    /// One arm's result for one fixture repeat. Pure data — file I/O
    /// (writing `run.json`/`summary.md` under `EvalResults/`) is a later
    /// task's job.
    struct AsrABFixtureArmRecord: Codable {
        let fixtureID: String
        let variant: String
        let armName: String
        let repeatIndex: Int
        let rawTopJoin: String
        let contentMajorCount: Int
        let minorCount: Int
        let contentMajors: [EvalDeviation]
        let minors: [EvalDeviation]
        let ceiling: CeilingRecovery
        let confidence: ConfidenceStats
        let gateFirings: Int
        let segmentCount: Int
        let alternativesPerFinal: [Int]
        let stopToLastFinalSeconds: Double
    }

    struct AsrABReport: Codable {
        let label: String
        /// Caller-supplied (matches `ConfigFingerprint.timestamp`'s format).
        let timestamp: String
        /// Caller-supplied (matches `ConfigFingerprint.gitCommit`).
        let gitCommit: String
        let arms: [String]
        let records: [AsrABFixtureArmRecord]
        let skipped: [String]
    }

    /// Renders `summary.md`: a per-arm aggregate table, a per-fixture
    /// comparison table, then a ceiling-recovery detail section. Ordering is
    /// deterministic (sorted by fixtureID, then armName, then repeatIndex)
    /// regardless of the input records' order, so re-running the renderer
    /// over the same report never produces a diff-noise reorder.
    static func summaryMarkdown(for report: AsrABReport) -> String {
        let records = report.records.sorted {
            ($0.fixtureID, $0.armName, $0.repeatIndex) < ($1.fixtureID, $1.armName, $1.repeatIndex)
        }

        var lines: [String] = []
        lines.append("# ASR A/B — \(report.label)")
        lines.append("")
        lines.append("- \(report.timestamp) · commit `\(report.gitCommit)` · arms: \(report.arms.joined(separator: ", "))")
        if !report.skipped.isEmpty {
            lines.append("- skipped: \(report.skipped.joined(separator: ", "))")
        }
        lines.append("")

        lines.append("## Per-arm aggregate")
        lines.append("| arm | content majors | minors | ceiling recovered/total | median-of-medians confidence | gate firings | mean stop→last-final (s) |")
        lines.append("|---|---|---|---|---|---|---|")
        for arm in report.arms {
            let armRecords = records.filter { $0.armName == arm }
            let totalContentMajors = armRecords.reduce(0) { $0 + $1.contentMajorCount }
            let totalMinors = armRecords.reduce(0) { $0 + $1.minorCount }
            let ceilingRecovered = armRecords.reduce(0) { $0 + $1.ceiling.recovered }
            let ceilingTotal = armRecords.reduce(0) { $0 + $1.ceiling.total }
            let medianOfMedians = median(ofSorted: armRecords.compactMap(\.confidence.median).sorted())
            let firings = armRecords.reduce(0) { $0 + $1.gateFirings }
            let meanStop = armRecords.isEmpty
                ? 0
                : armRecords.reduce(0) { $0 + $1.stopToLastFinalSeconds } / Double(armRecords.count)
            lines.append(String(
                format: "| %@ | %d | %d | %d/%d | %@ | %d | %.2f |",
                arm,
                totalContentMajors,
                totalMinors,
                ceilingRecovered,
                ceilingTotal,
                medianOfMedians.map { String(format: "%.2f", $0) } ?? "–",
                firings,
                meanStop
            ))
        }
        lines.append("")

        lines.append("## Per-fixture comparison")
        lines.append("| fixture | arm | repeat | content majors | ceiling recovered/total |")
        lines.append("|---|---|---|---|---|")
        for record in records {
            lines.append(String(
                format: "| %@ | %@ | %d | %d | %d/%d |",
                record.fixtureID,
                record.armName,
                record.repeatIndex,
                record.contentMajorCount,
                record.ceiling.recovered,
                record.ceiling.total
            ))
        }
        lines.append("")

        lines.append("## Ceiling recovery detail")
        let recoveredRecords = records.filter { $0.ceiling.recovered > 0 }
        if recoveredRecords.isEmpty {
            lines.append("- none")
        } else {
            for record in recoveredRecords {
                lines.append("- \(record.fixtureID)/\(record.armName) (repeat \(record.repeatIndex)): recovered \(record.ceiling.recovered)/\(record.ceiling.total)")
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }
}
