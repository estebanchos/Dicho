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
}
