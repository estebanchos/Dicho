import Foundation

/// Events emitted by the global hotkey monitor.
enum HotkeyEvent: Sendable {
    case startRequested
    case stopRequested
    case cancelRequested
}

/// Protocol seam for global hotkey monitoring. Production type: `HotkeyMonitor`.
///
/// Operates a listen-only CGEventTap on `flagsChanged` and `keyDown`.
/// Requires Accessibility trust; the system may silently disable the tap
/// (`tapDisabledByTimeout`) — implementations must detect and re-enable it.
protocol HotkeyMonitoring: AnyObject, Sendable {
    /// Async stream of hotkey events; begins delivering after `start()` is called.
    var events: AsyncStream<HotkeyEvent> { get }

    /// Installs the event tap and begins monitoring. Throws if Accessibility trust
    /// is not granted or the tap cannot be created.
    func start() throws

    /// Removes the event tap and stops monitoring.
    func stop()
}
