import Foundation

/// Protocol seam for capturing the frontmost application's context at the
/// moment dictation stops. Production type: `ActiveAppProvider`.
///
/// Implementations must be `@MainActor` because they read
/// `NSWorkspace.shared.frontmostApplication` and the time-varying properties
/// of `NSRunningApplication` are only guaranteed fresh within the current
/// main-run-loop turn. The coordinator calls `currentApp()` synchronously
/// inside the stop transition for that reason.
///
/// Returns `nil` when no frontmost app exists (rare — typically only at the
/// login window or during system transitions). The coordinator treats `nil`
/// the same as `.generalWriting`: no hint appended, baseline prompt.
protocol ActiveAppProviding: Sendable {
    @MainActor func currentApp() -> AppContext?
}
