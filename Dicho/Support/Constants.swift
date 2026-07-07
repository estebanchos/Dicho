import Foundation

/// Application-wide constants. All timing values are in seconds unless noted.
enum Constants {
    /// Delay before restoring the pasteboard after a synthetic paste.
    /// Must outlast the system's paste handling latency; too short races the
    /// paste (clipboard managers see our text, not the original), too long
    /// annoys power users who copy something immediately after dictating.
    /// See ARCHITECTURE.md gotcha #7.
    static let pasteboardRestoreDelay: TimeInterval = 0.4

    /// Maximum interval between two Ctrl press-releases to qualify as a
    /// double-tap. Matches ARCHITECTURE.md spec (400 ms).
    static let doubleTapThreshold: TimeInterval = 0.4

    /// Per-chunk Foundation Models cleanup timeout. Exceeding this causes
    /// the coordinator to use the raw transcript for that chunk.
    static let cleanupChunkTimeout: TimeInterval = 5.0

    /// Token budget per cleanup chunk (approximate; enforced by CleanupService).
    /// Keeps individual FoundationModels requests well within session limits.
    static let cleanupChunkTokenBudget: Int = 512

    /// How long the HUD surfaces a `DictationNotice` before auto-dismissing.
    /// Long enough to read status and error messages ("Cleanup unavailable",
    /// "Microphone permission missing"); short enough not to linger.
    static let noticeDisplayDuration: TimeInterval = 4.0

    /// Minimum word count required for `CleanupService.clean(_:appContext:)`
    /// to invoke the model. Shorter inputs are passed through unchanged.
    /// Observed during M7 manual verification: the on-device Foundation Models
    /// model occasionally echoes its own guided-generation system prompt
    /// (`"response format ... schema: { name: CleanedText ..."`) when given a
    /// single-token input. Single-word inputs barely benefit from cleanup,
    /// so the trade-off is favorable.
    static let cleanupMinWordsForCleanup: Int = 2

    /// Minimum-run-confidence threshold below which a finalized transcript
    /// segment becomes a rescoring candidate (see `RescoringGate`). Segments
    /// at or above the threshold always pass through as the transcriber's top
    /// hypothesis. Initial value chosen from the M10 C0 spike (2026-07-06):
    /// clean speech scored 0.84–1.00 while the one genuinely ambiguous segment
    /// scored 0.76 — tuned against real dictation in the 10.6 manual A/B.
    static let rescoringConfidenceThreshold: Double = 0.85
}
