import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Production text inserter.
///
/// Strategy per ARCHITECTURE.md §TextInserter:
///   1. Save the current `NSPasteboard.general` string.
///   2. Write the new text to the pasteboard.
///   3. If Accessibility is not trusted, throw `accessibilityUnavailable` —
///      the new text remains in the pasteboard so the user can paste manually.
///   4. Ask the system-wide AX for the focused element. If no element is
///      focused, or the element does not accept text input, throw
///      `noFocusedTextField` — again the new text remains in the pasteboard
///      (without this check, `CGEvent.post` would silently fail-into-the-void
///      because the event has no recipient, leaving the user with neither a
///      pasted result nor a clipboard they could fall back to).
///   5. Post a synthetic Cmd+V (flags set on both keyDown and keyUp, posted
///      to `cghidEventTap`) to paste at the cursor.
///   6. Sleep `Constants.pasteboardRestoreDelay`, then restore the prior
///      string — but only if the pasteboard's change count is exactly what we
///      wrote (the user may have copied something else mid-paste; don't
///      trample it).
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

        guard focusedElementAcceptsTextInput() else {
            // Leave the new text on the pasteboard so the user can paste it
            // manually once they focus a field; do not restore the prior
            // clipboard.
            throw InsertionError.noFocusedTextField
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

    /// Best-effort detection of whether the currently focused UI element will
    /// accept a synthetic paste. We treat the focused element as a text input
    /// when either:
    ///   - its `kAXSelectedTextAttribute` is settable (most NSText-backed
    ///     fields including code editors), or
    ///   - its `kAXRoleAttribute` is `AXTextField` / `AXTextArea` (covers
    ///     fields that don't expose `kAXSelectedTextAttribute` but are
    ///     unambiguously text input).
    /// Returns `false` when no element is focused or AX queries fail, which is
    /// the conservative answer ("text stays on clipboard, user pastes manually").
    private func focusedElementAcceptsTextInput() -> Bool {
        let systemElement = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        guard
            AXUIElementCopyAttributeValue(
                systemElement,
                kAXFocusedUIElementAttribute as CFString,
                &focused
            ) == .success,
            let element = focused,
            CFGetTypeID(element) == AXUIElementGetTypeID()
        else { return false }
        let axElement = element as! AXUIElement

        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(
            axElement,
            kAXSelectedTextAttribute as CFString,
            &settable
        ) == .success, settable.boolValue {
            return true
        }

        var role: AnyObject?
        guard
            AXUIElementCopyAttributeValue(
                axElement,
                kAXRoleAttribute as CFString,
                &role
            ) == .success,
            let roleString = role as? String
        else { return false }

        return roleString == kAXTextFieldRole
            || roleString == kAXTextAreaRole
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
