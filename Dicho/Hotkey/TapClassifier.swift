import Foundation

/// A raw event fed to TapClassifier by HotkeyMonitor.
enum TapEvent: Sendable {
    /// Ctrl key pressed; timestamp from CGEvent.
    case ctrlDown(at: TimeInterval)
    /// Ctrl key released; timestamp from CGEvent.
    case ctrlUp(at: TimeInterval)
    /// A non-Ctrl, non-Esc key was pressed while Ctrl was held (e.g. Ctrl+C).
    case interruptingKey
    /// The Escape key was pressed.
    case escape
}

/// A gesture outcome produced by TapClassifier.
enum TapGesture: Equatable, Sendable {
    /// Double-tap completed: start dictation.
    case activated
    /// Single tap while active: stop dictation.
    case deactivated
    /// Esc while active: discard and cancel.
    case cancelled
}

/// Pure value-type double-tap detector.
///
/// Feed it `TapEvent` values in arrival order; it returns a `TapGesture` when
/// a complete gesture is recognised, or `nil` while still accumulating input.
///
/// Thread-safety: this is a value type — callers are responsible for
/// serialising mutations when accessed from multiple contexts.
struct TapClassifier: Sendable {

    private(set) var isActive: Bool = false
    private var phase: Phase = .idle

    private enum Phase: Sendable {
        case idle
        case firstDown(at: TimeInterval)    // Ctrl held; first tap in progress
        case betweenTaps(at: TimeInterval)  // First tap clean; waiting for second
        case secondDown                      // Second Ctrl held; pending ctrlUp to activate
        case stopDown                        // Ctrl held while active; pending ctrlUp to stop
    }

    @discardableResult
    mutating func process(_ event: TapEvent) -> TapGesture? {
        isActive ? processActive(event) : processInactive(event)
    }

    // MARK: - Inactive path (double-tap to activate)

    private mutating func processInactive(_ event: TapEvent) -> TapGesture? {
        switch (phase, event) {

        case (.idle, .ctrlDown(let t)):
            phase = .firstDown(at: t)

        case (.firstDown, .ctrlUp(let t)):
            phase = .betweenTaps(at: t)

        case (.firstDown, .interruptingKey):
            // Ctrl+X combo; discard this tap and restart.
            phase = .idle

        case (.firstDown, .escape), (.firstDown, .ctrlDown):
            phase = .idle

        case (.betweenTaps(let t1), .ctrlDown(let t2)):
            if t2 - t1 <= Constants.doubleTapThreshold {
                phase = .secondDown
            } else {
                // Too slow; this ctrlDown starts a fresh first tap.
                phase = .firstDown(at: t2)
            }

        case (.betweenTaps, .escape), (.betweenTaps, .interruptingKey):
            phase = .idle

        case (.secondDown, .ctrlUp):
            phase = .idle
            isActive = true
            return .activated

        case (.secondDown, .interruptingKey), (.secondDown, .escape):
            phase = .idle

        default:
            break
        }
        return nil
    }

    // MARK: - Active path (stop or cancel)

    private mutating func processActive(_ event: TapEvent) -> TapGesture? {
        switch (phase, event) {

        case (.idle, .escape):
            isActive = false
            return .cancelled

        case (.idle, .ctrlDown):
            phase = .stopDown

        case (.stopDown, .ctrlUp):
            phase = .idle
            isActive = false
            return .deactivated

        case (.stopDown, .escape):
            // Esc overrides even when Ctrl is held.
            phase = .idle
            isActive = false
            return .cancelled

        case (.stopDown, .interruptingKey):
            // Ctrl+X combo while active: abort the stop attempt.
            phase = .idle

        default:
            break
        }
        return nil
    }
}
