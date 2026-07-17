import Foundation
@testable import Dicho

/// M12 eval-harness scoring model. Pure value types — Codable so they
/// serialize straight into `run.json` reports.

enum DeviationSeverity: String, Codable, Equatable {
    case minor
    case major
}

enum DeviationKind: String, Codable, Equatable {
    case casing
    case punctuation
    case whitespace
    case numberFormat = "number-format"
    case substitution
    case insertion
    case deletion
    case fillerResidue = "filler-residue"
    case assertionFailure = "assertion-failure"

    /// Severity taxonomy locked with the M12 spec: formatting-level edits are
    /// minor; content-level edits, leftover fillers, and fixture assertions
    /// are major.
    var defaultSeverity: DeviationSeverity {
        switch self {
        case .casing, .punctuation, .whitespace, .numberFormat:
            return .minor
        case .substitution, .insertion, .deletion, .fillerResidue, .assertionFailure:
            return .major
        }
    }
}

/// Which pipeline layer a MAJOR deviation is attributable to, derived from
/// the captured intermediates (raw ASR top-hypothesis join, rescored text,
/// per-segment n-best candidates).
enum DeviationLayer: String, Codable, Equatable {
    /// Truth absent from the ASR output AND every n-best candidate —
    /// unreachable by any downstream tuning. Reported, never gates.
    case asrCeiling = "asr-ceiling"
    /// Truth was available at the rescoring layer (in the raw top join or a
    /// candidate) but the selector kept/chose the wrong form.
    case rescoringMissed = "rescoring-missed"
    /// Offending text survived into cleanup's input and cleanup's rules were
    /// the last chance to remove/fix it.
    case cleanupMissed = "cleanup-missed"
    /// Cleanup damaged text that was still correct in its input (or invented
    /// content that was never there).
    case cleanupIntroduced = "cleanup-introduced"
}

struct EvalDeviation: Codable, Equatable {
    let kind: DeviationKind
    let severity: DeviationSeverity
    let expected: String?
    let actual: String?
    var layer: DeviationLayer?

    init(kind: DeviationKind, expected: String? = nil, actual: String? = nil, layer: DeviationLayer? = nil) {
        self.kind = kind
        self.severity = kind.defaultSeverity
        self.expected = expected
        self.actual = actual
        self.layer = layer
    }
}

/// Captured pipeline intermediates for one repeat, used for layer attribution.
struct EvalIntermediates {
    /// Trim-joined top hypotheses of all finalized segments (pre-rescoring).
    let rawTopJoin: String
    /// The rescoring pass's output — cleanup's input.
    let rescoredText: String
    /// The finalized segments with their n-best alternatives.
    let segments: [TranscriptUpdate]
}
