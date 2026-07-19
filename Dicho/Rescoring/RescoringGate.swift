import Foundation

/// Deterministic gate deciding which finalized transcript segments are worth
/// sending to the model selector (M10 rescoring, optimization Candidate C).
///
/// The gate is pure logic — no model, no Speech framework — so rescoring cost
/// is bounded: the selector only ever sees segments that are BOTH uncertain
/// (low minimum per-run confidence) AND genuinely ambiguous (alternatives that
/// differ lexically, not just in punctuation or casing). Everything else
/// passes through as the transcriber's top hypothesis.
///
/// `nonisolated`: pure functions over Sendable data, opted out of the module's
/// MainActor default so any isolation (eval scoring, tests) can call them.
nonisolated enum RescoringGate {

    /// Returns `true` when `update` should be routed to the selector.
    ///
    /// Pass-through (never rescore) when any of these hold:
    /// - the update is volatile (alternatives/confidence are absent or an echo);
    /// - confidence is missing — no signal, never rescore blindly;
    /// - confidence is at or above `threshold`;
    /// - fewer than two alternatives (`alternatives[0]` echoes the primary
    ///   hypothesis, so one entry means no actual choice);
    /// - all alternatives normalize to the same word sequence (punctuation or
    ///   casing variants only — the C0 spike showed these dominate).
    static func needsRescoring(_ update: TranscriptUpdate, threshold: Double) -> Bool {
        guard update.isFinal else { return false }
        guard let confidence = update.confidence, confidence < threshold else { return false }
        guard update.alternatives.count >= 2 else { return false }

        let normalizedForms = Set(update.alternatives.map(normalize))
        return normalizedForms.count > 1
    }

    /// `true` when two candidates carry the same word sequence and differ only
    /// in punctuation, whitespace, or casing. `RescoringService` uses this to
    /// snap a punctuation-only selector choice back to the top hypothesis —
    /// a selection is only worth keeping when the WORDS changed.
    static func lexicallyEquivalent(_ a: String, _ b: String) -> Bool {
        normalize(a) == normalize(b)
    }

    /// Collapses a candidate to its lexical content: lowercased alphanumerics
    /// only, so punctuation, whitespace, and casing differences vanish.
    private static func normalize(_ candidate: String) -> String {
        String(candidate.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }).lowercased()
    }
}
