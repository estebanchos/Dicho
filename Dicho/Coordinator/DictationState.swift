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
    /// User attempted to record but microphone authorization is not granted.
    /// Onboarding will offer the System Settings deep link in M6.
    case microphonePermissionMissing

    /// Single source of truth for the user-facing string each notice renders to.
    var displayText: String {
        switch self {
        case .nothingHeard:                 return "Nothing heard"
        case .cleanupUnavailable:           return "Cleanup unavailable"
        case .insertionFailed:              return "Copied to clipboard — paste manually"
        case .audioCaptureFailed:           return "Audio capture failed"
        case .microphonePermissionMissing:  return "Microphone access required — open System Settings"
        }
    }
}
