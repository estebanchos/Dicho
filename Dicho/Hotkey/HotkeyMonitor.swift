import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

// Converts Mach absolute time (CGEventTimestamp) to seconds.
// Computed once at load time; safe to read from any thread.
private let machToSeconds: Double = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return Double(info.numer) / Double(info.denom) / 1_000_000_000
}()

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
/// Installs a listen-only `CGEventTap` on a dedicated background `CFRunLoop` thread.
/// Feeds raw events into a `TapClassifier` and yields `HotkeyEvent` values on the
/// `events` stream. Automatically re-enables the tap on `tapDisabledByTimeout`.
///
/// - Note: `@unchecked Sendable` — mutable state is accessed exclusively from
///   the dedicated run loop thread (`classifier`, `ctrlIsDown`) or written once
///   before callbacks begin (`eventTap`, `tapRunLoop`). Thread ownership is
///   documented per property.
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

        // Written on caller thread before the run loop thread starts; all subsequent
        // reads happen only after CFRunLoopRun() begins (guaranteed happens-before).
        eventTap = tap

        Thread.detachNewThread { [tap, weak self] in
            let rl = CFRunLoopGetCurrent()!
            // tapRunLoop: assigned from background thread; caller reads it only in stop(),
            // which follows the full activation flow — benign race acknowledged.
            self?.tapRunLoop = rl
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(rl, source, .commonModes)
            CFRunLoopRun()
        }
    }

    func stop() {
        if let tap = eventTap {
            // Disabling the tap synchronously prevents any new callbacks from firing.
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        if let rl = tapRunLoop {
            CFRunLoopStop(rl)
            tapRunLoop = nil
        }
        continuation.finish()
    }

    // MARK: - Private

    private let stream: AsyncStream<HotkeyEvent>
    private let continuation: AsyncStream<HotkeyEvent>.Continuation

    // Written once in start() before callbacks begin; read in handleRaw (tap thread) and stop().
    nonisolated(unsafe) private var eventTap: CFMachPort?
    // Set from the run loop thread shortly after start; read in stop() for cleanup.
    nonisolated(unsafe) private var tapRunLoop: CFRunLoop?
    // Mutated and read exclusively on the CGEventTap run loop thread.
    nonisolated(unsafe) private var classifier = TapClassifier()
    // Tracks current Ctrl key state; read and written exclusively on the tap thread.
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
                let t = Double(event.timestamp) * machToSeconds
                emit(classifier.process(.ctrlDown(at: t)))
            } else if !hasCtrl, ctrlIsDown {
                ctrlIsDown = false
                let t = Double(event.timestamp) * machToSeconds
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
