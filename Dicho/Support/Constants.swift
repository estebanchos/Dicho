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
    /// hypothesis. Initially 0.85 from the C0 spike; lowered to 0.70 after the
    /// round-2 field test (2026-07-07): every firing in the 0.70–0.85 band
    /// produced no change (or a selector miss), so the band cost latency for
    /// zero quality — all real wins occurred below 0.70.
    static let rescoringConfidenceThreshold: Double = 0.70

    /// Per-segment timeout for the rescoring selector (`RescoringService`).
    /// Selection is a single small guided-generation turn (an index), so it
    /// should complete well under this; on expiry the segment keeps the
    /// transcriber's top hypothesis. Bounded so rescoring can never noticeably
    /// delay insertion even with several ambiguous segments.
    static let rescoringSegmentTimeout: TimeInterval = 2.0
}
