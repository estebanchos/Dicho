import AppKit

/// Production `ActiveAppProviding`. A thin AppKit shim over
/// `NSWorkspace.shared.frontmostApplication`. Verified by the M7 manual
/// checklist — there are no unit tests for this layer because it touches
/// real system state.
@MainActor
final class ActiveAppProvider: ActiveAppProviding {

    func currentApp() -> AppContext? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let bundleID = app.bundleIdentifier
        return AppContext(
            bundleIdentifier: bundleID,
            localizedName: app.localizedName,
            category: AppCategory.from(bundleIdentifier: bundleID)
        )
    }
}
