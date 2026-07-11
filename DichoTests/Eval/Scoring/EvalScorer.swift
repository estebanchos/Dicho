import Foundation
@testable import Dicho

/// M12 eval-harness scorer: aligns actual pipeline output against a fixture's
/// expected text, classifies each difference per the locked taxonomy
/// (MINOR = casing / punctuation / whitespace / number-format;
/// MAJOR = content edits, leftover fillers, assertion failures), and
/// attributes majors to a pipeline layer when intermediates are provided.
/// Pure logic — fully unit-tested in the normal gate.
enum EvalScorer {

    /// Words whose insertion means cleanup failed at its primary job.
    static let fillerLexicon: Set<String> = ["um", "uh", "uhm", "er", "ah", "hmm"]

    static func score(
        expected: String,
        actual: String,
        mustContain: [String] = [],
        mustNotContain: [String] = [],
        intermediates: EvalIntermediates? = nil
    ) -> [EvalDeviation] {
        var deviations: [EvalDeviation] = []

        // Whitespace hygiene is checked on the raw string — tokenization
        // erases it. One deviation covers the whole text.
        if actual != actual.trimmingCharacters(in: .whitespacesAndNewlines) || actual.contains("  ") {
            deviations.append(EvalDeviation(kind: .whitespace, actual: "leading/trailing or doubled whitespace"))
        }

        let expectedUnits = EvalTokenizer.units(expected)
        let actualUnits = EvalTokenizer.units(actual)
        deviations += classify(align(expected: expectedUnits, actual: actualUnits))
        deviations += assertionFailures(actual: actual, mustContain: mustContain, mustNotContain: mustNotContain)

        if let intermediates {
            deviations = deviations.map { attribute($0, in: intermediates) }
        }
        return deviations
    }

    // MARK: - Alignment (word-level Levenshtein with backtrace)

    enum AlignmentOp {
        case match(expected: EvalTokenizer.Unit, actual: EvalTokenizer.Unit)
        case substitute(expected: EvalTokenizer.Unit, actual: EvalTokenizer.Unit)
        case delete(expected: EvalTokenizer.Unit)
        case insert(actual: EvalTokenizer.Unit)
    }

    static func align(expected: [EvalTokenizer.Unit], actual: [EvalTokenizer.Unit]) -> [AlignmentOp] {
        let rows = expected.count + 1
        let cols = actual.count + 1
        var dp = Array(repeating: Array(repeating: 0, count: cols), count: rows)
        for i in 0..<rows { dp[i][0] = i }
        for j in 0..<cols { dp[0][j] = j }
        for i in 1..<rows {
            for j in 1..<cols {
                let equal = expected[i - 1].normalized == actual[j - 1].normalized
                dp[i][j] = min(
                    dp[i - 1][j - 1] + (equal ? 0 : 1),
                    dp[i - 1][j] + 1,
                    dp[i][j - 1] + 1
                )
            }
        }

        var ops: [AlignmentOp] = []
        var i = expected.count
        var j = actual.count
        while i > 0 || j > 0 {
            if i > 0, j > 0 {
                let equal = expected[i - 1].normalized == actual[j - 1].normalized
                if dp[i][j] == dp[i - 1][j - 1] + (equal ? 0 : 1) {
                    ops.append(equal
                        ? .match(expected: expected[i - 1], actual: actual[j - 1])
                        : .substitute(expected: expected[i - 1], actual: actual[j - 1]))
                    i -= 1
                    j -= 1
                    continue
                }
            }
            if j > 0, dp[i][j] == dp[i][j - 1] + 1 {
                ops.append(.insert(actual: actual[j - 1]))
                j -= 1
            } else {
                ops.append(.delete(expected: expected[i - 1]))
                i -= 1
            }
        }
        return ops.reversed()
    }

    // MARK: - Classification

    private static func classify(_ ops: [AlignmentOp]) -> [EvalDeviation] {
        var deviations: [EvalDeviation] = []
        for op in ops {
            switch op {
            case .match(let expected, let actual):
                if expected.surface != actual.surface {
                    if expected.folded == actual.folded {
                        deviations.append(EvalDeviation(kind: .casing, expected: expected.surface, actual: actual.surface))
                    } else {
                        // Normalized forms matched but folded surfaces differ —
                        // only number normalization can produce this.
                        deviations.append(EvalDeviation(kind: .numberFormat, expected: expected.surface, actual: actual.surface))
                    }
                }
                if expected.leadingPunctuation != actual.leadingPunctuation
                    || expected.trailingPunctuation != actual.trailingPunctuation {
                    deviations.append(EvalDeviation(
                        kind: .punctuation,
                        expected: expected.leadingPunctuation + expected.surface + expected.trailingPunctuation,
                        actual: actual.leadingPunctuation + actual.surface + actual.trailingPunctuation
                    ))
                }
            case .substitute(let expected, let actual):
                deviations.append(EvalDeviation(kind: .substitution, expected: expected.surface, actual: actual.surface))
            case .delete(let expected):
                deviations.append(EvalDeviation(kind: .deletion, expected: expected.surface))
            case .insert(let actual):
                let kind: DeviationKind = fillerLexicon.contains(actual.normalized) ? .fillerResidue : .insertion
                deviations.append(EvalDeviation(kind: kind, actual: actual.surface))
            }
        }
        return deviations
    }

    // MARK: - Assertions

    /// Single-word needles are word-boundary matched (so "um" never fires on
    /// "umbrella"); multi-word needles are substring matched on
    /// whitespace-collapsed text. Both directions ALSO consult the
    /// number-normalized unit sequence, so "seven percent" is satisfied by
    /// "7%" and "twenty" is caught as "20".
    private static func assertionFailures(
        actual: String,
        mustContain: [String],
        mustNotContain: [String]
    ) -> [EvalDeviation] {
        var deviations: [EvalDeviation] = []
        for needle in mustContain where !appears(needle, in: actual) {
            deviations.append(EvalDeviation(kind: .assertionFailure, expected: needle))
        }
        for needle in mustNotContain where appears(needle, in: actual) {
            deviations.append(EvalDeviation(kind: .assertionFailure, actual: needle))
        }
        return deviations
    }

    /// Case-, punctuation-, and number-format-insensitive presence check.
    static func appears(_ needle: String, in text: String) -> Bool {
        // Raw-text check first: word-boundary regex for single words,
        // substring on collapsed whitespace for phrases.
        let collapsedText = collapseWhitespace(text)
        let collapsedNeedle = collapseWhitespace(needle)
        if collapsedNeedle.contains(" ") {
            if collapsedText.range(of: collapsedNeedle, options: [.caseInsensitive]) != nil { return true }
        } else if !collapsedNeedle.isEmpty {
            let escaped = NSRegularExpression.escapedPattern(for: collapsedNeedle)
            if collapsedText.range(of: "\\b\(escaped)\\b", options: [.regularExpression, .caseInsensitive]) != nil {
                return true
            }
        }
        // Normalized-unit fallback (numbers, punctuation, casing).
        return EvalTokenizer.containsSubsequence(
            EvalTokenizer.normalizedSequence(text),
            EvalTokenizer.normalizedSequence(needle)
        )
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    // MARK: - Layer attribution

    /// Attributes a MAJOR deviation to a pipeline layer.
    ///
    /// Missing-truth deviations (substitution/deletion/mustContain miss):
    /// walk backward through the pipeline asking where the truth was last
    /// seen. Present-offender deviations (insertion/filler/mustNotContain
    /// hit): cleanup either failed to remove text it received (missed) or
    /// added text it never received (introduced).
    private static func attribute(_ deviation: EvalDeviation, in intermediates: EvalIntermediates) -> EvalDeviation {
        guard deviation.severity == .major else { return deviation }
        var attributed = deviation

        switch deviation.kind {
        case .substitution, .deletion:
            attributed.layer = missingTruthLayer(deviation.expected, in: intermediates)
        case .insertion, .fillerResidue:
            attributed.layer = presentOffenderLayer(deviation.actual, in: intermediates)
        case .assertionFailure:
            if deviation.expected != nil {
                attributed.layer = missingTruthLayer(deviation.expected, in: intermediates)
            } else {
                attributed.layer = presentOffenderLayer(deviation.actual, in: intermediates)
            }
        default:
            break
        }
        return attributed
    }

    private static func missingTruthLayer(_ truth: String?, in intermediates: EvalIntermediates) -> DeviationLayer {
        guard let truth else { return .asrCeiling }
        if appears(truth, in: intermediates.rescoredText) { return .cleanupIntroduced }
        if appears(truth, in: intermediates.rawTopJoin) { return .rescoringMissed }
        let inCandidates = intermediates.segments.contains { segment in
            segment.alternatives.contains { appears(truth, in: $0) }
        }
        return inCandidates ? .rescoringMissed : .asrCeiling
    }

    private static func presentOffenderLayer(_ offender: String?, in intermediates: EvalIntermediates) -> DeviationLayer {
        guard let offender else { return .cleanupIntroduced }
        return appears(offender, in: intermediates.rescoredText) ? .cleanupMissed : .cleanupIntroduced
    }
}
