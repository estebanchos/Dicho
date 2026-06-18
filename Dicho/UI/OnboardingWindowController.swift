import AppKit
import SwiftUI

/// Manages the onboarding `NSWindow`. Creates it lazily on first `show()` call
/// and destroys it when the window closes, so repeated `show()` calls create a
/// fresh window each time (permissions may have changed between appearances).
@MainActor
final class OnboardingWindowController: NSObject {

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
        let view = OnboardingView(settings: settings) { [weak self] in
            self?.close()
        }
        let controller = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: controller)
        w.title = "Dicho Setup"
        w.styleMask = [.titled, .closable]
        w.isMovableByWindowBackground = true
        w.setFrameAutosaveName("DichoOnboarding")
        w.delegate = self
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.orderOut(nil)
        window = nil
    }
}

extension OnboardingWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
