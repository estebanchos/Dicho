import ApplicationServices
import CoreGraphics
import Foundation

/// Virtual key code for the Escape key (Carbon kVK_Escape = 53).
private let kVKEscape: CGKeyCode = 53

/// File-scope CGEventTap callback. `refcon` carries an unretained HotkeyMonitor.
/// Using a free function (not a closure) satisfies the @convention(c) requirement.
private func tapEventCallback(
    _: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let refcon {
        Unmanaged<HotkeyMonitor>.fromOpaque(refcon)
            .takeUnretainedValue()
            .handleRaw(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}

/// Production implementation of `HotkeyMonitoring`.
///
/// Installs a listen-only `CGEventTap` sourced into the **main run loop**, which is
/// already running (NSApplication's event loop). Per Apple's documentation, the
/// callback is "invoked from the run loop to which the event tap is added as a source"
/// — using the main run loop guarantees continuous delivery without managing a
/// separate thread's lifecycle.
///
/// - Note: `@unchecked Sendable` — `classifier` and `ctrlIsDown` are mutated
///   exclusively from the CGEventTap callback, which is always invoked on the main
///   run loop thread. `eventTap` is written once on the main thread in `start()`
///   before callbacks begin.
final class HotkeyMonitor: HotkeyMonitoring, @unchecked Sendable {

    // MARK: - HotkeyMonitoring

    var events: AsyncStream<HotkeyEvent> { stream }

    func start() throws {
        // Silent check only — prompting is the caller's (onboarding) responsibility.
        guard AXIsProcessTrustedWithOptions(nil) else {
            throw HotkeyMonitorError.accessibilityNotGranted
        }

        let eventsOfInterest: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventsOfInterest,
            callback: tapEventCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw HotkeyMonitorError.tapCreationFailed
        }

        eventTap = tap

        // Add the tap source to the main run loop, which is already running.
        // Apple docs: "invoke from the run loop to which the event tap is added as a source."
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        continuation.finish()
    }

    // MARK: - Private

    private let stream: AsyncStream<HotkeyEvent>
    private let continuation: AsyncStream<HotkeyEvent>.Continuation

    // Written once in start() on the main thread; read in handleRaw (main run loop callback).
    nonisolated(unsafe) private var eventTap: CFMachPort?
    // Mutated and read exclusively from the CGEventTap callback on the main run loop.
    nonisolated(unsafe) private var classifier = TapClassifier()
    // Tracks Ctrl key state; mutated and read exclusively from the tap callback.
    nonisolated(unsafe) private var ctrlIsDown = false

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: HotkeyEvent.self)
    }

    // MARK: - Event handling (called from tap run loop thread)

    fileprivate func handleRaw(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system may silence the tap under load. Re-enable so hotkeys keep working.
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }

        case .flagsChanged:
            let hasCtrl = event.flags.contains(.maskControl)
            if hasCtrl, !ctrlIsDown {
                ctrlIsDown = true
                let t = Double(event.timestamp) / 1_000_000_000
                emit(classifier.process(.ctrlDown(at: t)))
            } else if !hasCtrl, ctrlIsDown {
                ctrlIsDown = false
                let t = Double(event.timestamp) / 1_000_000_000
                emit(classifier.process(.ctrlUp(at: t)))
            }

        case .keyDown:
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            if keyCode == kVKEscape {
                emit(classifier.process(.escape))
            } else if ctrlIsDown {
                // A non-Esc key pressed while Ctrl is held (e.g. Ctrl+C): abort the tap.
                emit(classifier.process(.interruptingKey))
            }

        default:
            break
        }
    }

    private func emit(_ gesture: TapGesture?) {
        switch gesture {
        case .activated:   continuation.yield(.startRequested)
        case .deactivated: continuation.yield(.stopRequested)
        case .cancelled:   continuation.yield(.cancelRequested)
        case nil:          break
        }
    }
}

enum HotkeyMonitorError: Error, Sendable {
    case accessibilityNotGranted
    case tapCreationFailed
}
