import Foundation

/// The state machine states for a single dictation session.
enum DictationState: Equatable, Sendable {
    case idle
    case recording
    /// Mic stopped; transcription engine is finalizing remaining results.
    case transcribing
    /// Final transcript ready; Foundation Models cleanup in progress.
    case cleaning(transcript: String)
    /// Cleaned (or raw) text being inserted at the cursor.
    case inserting(text: String)
}

/// Non-blocking notices surfaced to the UI layer after coordinator transitions.
enum DictationNotice: Equatable, Sendable {
    case nothingHeard
    case cleanupUnavailable
    case insertionFailed
    case audioCaptureFailed
}
