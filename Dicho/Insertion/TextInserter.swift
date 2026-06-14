import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Production text inserter.
///
/// Strategy per ARCHITECTURE.md §TextInserter:
///   1. Save the current `NSPasteboard.general` string.
///   2. Write the new text to the pasteboard.
///   3. If Accessibility is not trusted, throw `InsertionError.accessibilityUnavailable`
///      — the new text remains in the pasteboard so the user can paste manually.
///   4. Otherwise post a synthetic Cmd+V (flags set on both keyDown and keyUp,
///      posted to `cghidEventTap`) to paste at the cursor.
///   5. Sleep `Constants.pasteboardRestoreDelay`, then restore the prior string
///      — but only if the pasteboard's change count is exactly what we wrote
///      (the user may have copied something else mid-paste; don't trample it).
@MainActor
final class TextInserter: TextInserting {

    /// Virtual key code for 'V' on the standard ANSI layout (kVK_ANSI_V = 9).
    private static let virtualKeyV: CGKeyCode = 9

    func insert(_ text: String) async throws {
        let pasteboard = NSPasteboard.general
        let savedString = pasteboard.string(forType: .string)

        let writtenChangeCount = pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard AXIsProcessTrusted() else {
            throw InsertionError.accessibilityUnavailable
        }

        try postCommandV()

        try? await Task.sleep(for: .seconds(Constants.pasteboardRestoreDelay))

        // Only restore if our text is still the latest pasteboard contents.
        // If the user copied something between the paste and the restore, leave
        // their newer copy alone.
        if pasteboard.changeCount == writtenChangeCount {
            pasteboard.clearContents()
            if let savedString {
                pasteboard.setString(savedString, forType: .string)
            }
        }
    }

    /// Posts a synthetic Cmd+V keystroke. Flags are set on both keyDown and
    /// keyUp per ARCHITECTURE.md gotcha #6; events go to `cghidEventTap` so they
    /// enter the system event stream at the same level as a real hardware key.
    private func postCommandV() throws {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: Self.virtualKeyV,
                keyDown: true
              ),
              let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: Self.virtualKeyV,
                keyDown: false
              ) else {
            throw InsertionError.accessibilityUnavailable
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
