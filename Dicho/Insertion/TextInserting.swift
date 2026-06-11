import Foundation

/// Protocol seam for text insertion at the cursor. Production type: `TextInserter`.
///
/// Strategy: save current pasteboard → write cleaned text → synthetic Cmd+V via
/// `CGEvent` posted to `cghidEventTap` → restore prior pasteboard after
/// `Constants.pasteboardRestoreDelay`.
///
/// If the event cannot be posted (Accessibility revoked), the implementation must
/// throw `InsertionError.accessibilityUnavailable`; the coordinator then leaves
/// the text in the pasteboard and notifies the user.
protocol TextInserting: AnyObject, Sendable {
    /// Inserts `text` at the current cursor position in the frontmost app.
    func insert(_ text: String) async throws
}

/// Errors surfaced by `TextInserting` implementations.
enum InsertionError: Error, Sendable {
    /// Accessibility permission was revoked; synthetic events cannot be posted.
    case accessibilityUnavailable
    /// The paste event was posted but no focused text field was detected.
    case noFocusedTextField
}
