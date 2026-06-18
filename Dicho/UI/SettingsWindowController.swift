import AppKit
import SwiftUI

/// Manages the Settings `NSWindow`. Creates it lazily on first `show()` call;
/// re-uses the existing window if already open.
@MainActor
final class SettingsWindowController: NSObject {

    private let settings: AppSettings
    private var window: NSWindow?

    init(settings: AppSettings) {
        self.settings = settings
    }

    // MARK: - Public

    func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = SettingsView(settings: settings)
        let controller = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: controller)
        w.title = "Dicho Settings"
        w.styleMask = [.titled, .closable]
        w.isMovableByWindowBackground = true
        w.setFrameAutosaveName("DichoSettings")
        w.delegate = self
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension SettingsWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
