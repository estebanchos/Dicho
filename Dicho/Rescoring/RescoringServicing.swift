import Foundation

/// Protocol seam for n-best transcript rescoring (M10, optimization
/// Candidate C). Production type: `RescoringService`; tests use
/// `FakeRescoringService`.
///
/// Sits between transcription and cleanup: takes the dictation's finalized
/// segments (with alternatives + confidence) and returns the reassembled
/// transcript with ambiguous segments resolved to their best candidate.
/// Total and non-throwing — any failure inside degrades that segment to the
/// transcriber's top hypothesis, so callers need no error policy. Applies in
/// raw mode too: rescoring is transcription-layer repair, not cleanup.
@MainActor
protocol RescoringServicing: AnyObject {
    /// Warms the selector model so the first ambiguous segment isn't delayed
    /// by model loading. Call when recording starts, alongside cleanup prewarm.
    func prewarm()

    /// Reassembles `segments` into the final transcript, replacing each
    /// gate-flagged segment with the model-chosen candidate. Segment texts are
    /// trimmed and joined with single spaces (the M9 whitespace rule).
    func rescore(_ segments: [TranscriptUpdate]) async -> String
}
