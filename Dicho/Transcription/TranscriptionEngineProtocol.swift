import Foundation

/// A single transcription result from the speech engine.
///
/// Volatile results (isFinal == false) are provisional and will be superseded;
/// the HUD must *replace* — not append — the volatile text for its range.
/// Final results are stable and should be forwarded to the cleanup queue.
struct TranscriptUpdate: Sendable {
    /// The recognized text for this segment.
    let text: String
    /// The range within the full in-progress transcript that this update covers.
    let range: NSRange?
    /// Whether this result is final (true) or volatile/provisional (false).
    let isFinal: Bool
    /// N-best candidate transcriptions for a FINAL segment, most likely first.
    /// Mirrors `SpeechTranscriber.Result.alternatives`, which includes the
    /// primary hypothesis at index 0 (verified in the M10 C0 spike) — so this
    /// is the full candidate list, not extras beyond `text`. Empty for
    /// volatile results and when the engine doesn't report alternatives.
    let alternatives: [String]
    /// Minimum per-run transcription confidence for a FINAL segment (0…1);
    /// nil for volatile results or engines without confidence reporting.
    /// The minimum — not the average — is the rescoring gate signal: one
    /// uncertain word makes the whole segment a rescoring candidate.
    let confidence: Double?

    init(
        text: String,
        range: NSRange?,
        isFinal: Bool,
        alternatives: [String] = [],
        confidence: Double? = nil
    ) {
        self.text = text
        self.range = range
        self.isFinal = isFinal
        self.alternatives = alternatives
        self.confidence = confidence
    }
}

/// Protocol seam for on-device speech transcription. Production type: `TranscriptionEngine`.
///
/// Uses `SpeechAnalyzer` + `SpeechTranscriber` (macOS 26), locale en-US, on-device.
/// The production type consumes audio from `AudioCapture` and produces an async
/// sequence of `TranscriptUpdate` values. Model availability is checked via
/// `AssetInventory` before the first session.
protocol TranscriptionEngineProtocol: AnyObject, Sendable {
    /// Async stream of transcript updates (volatile and final).
    var updates: AsyncStream<TranscriptUpdate> { get }

    /// Begins a transcription session. Audio must already be flowing from
    /// `AudioCapture` before this is called in production.
    func start() async throws

    /// Ends the session and finalizes any in-flight results.
    func stop() async
}
