import AppKit

/// Application delegate responsible for the menu-bar status item and top-level
/// app lifecycle. Expanded in later milestones to wire the full pipeline.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Enforce menu-bar-only presentation; mirrors LSUIElement = YES in Info.plist.
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Dicho")

        let menu = NSMenu()
        menu.addItem(
            NSMenuItem(title: "Quit Dicho", action: #selector(quit), keyEquivalent: "q")
        )
        statusItem?.menu = menu
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
