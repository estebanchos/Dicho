import AppKit

/// Application delegate responsible for the menu-bar status item and top-level
/// app lifecycle. Expanded in later milestones to wire the full pipeline.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

#if DEBUG
    private var hotkeyMonitor: HotkeyMonitor?
    private var hotkeyTask: Task<Void, Never>?
#endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Enforce menu-bar-only presentation; mirrors LSUIElement = YES in Info.plist.
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
#if DEBUG
        startDebugHotkeyMonitor()
#endif
    }

    func applicationWillTerminate(_ notification: Notification) {
#if DEBUG
        hotkeyTask?.cancel()
        hotkeyMonitor?.stop()
#endif
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

    // MARK: - Debug hotkey smoke-test

#if DEBUG
    private var accessibilityPollTimer: Timer?

    private func startDebugHotkeyMonitor() {
        if AXIsProcessTrustedWithOptions(nil) {
            launchHotkeyMonitor()
            return
        }
        // On modern macOS, AXIsProcessTrustedWithOptions([prompt:true]) silently fails for
        // LSUIElement development builds. Open System Settings directly via URL instead.
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        )
        print("[DEBUG] Accessibility not granted.")
        print("[DEBUG] System Settings has been opened to Privacy & Security › Accessibility.")
        print("[DEBUG] Click '+' and add: \(Bundle.main.bundlePath)")
        print("[DEBUG] Enable the toggle — the monitor starts automatically within 1 second.")
        accessibilityPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            // Timer fires on main run loop; Task @MainActor makes the isolation explicit
            // to satisfy strict-concurrency checking.
            Task { @MainActor [weak self] in
                guard let self, AXIsProcessTrustedWithOptions(nil) else { return }
                self.accessibilityPollTimer?.invalidate()
                self.accessibilityPollTimer = nil
                self.launchHotkeyMonitor()
            }
        }
    }

    private func launchHotkeyMonitor() {
        let monitor = HotkeyMonitor()
        hotkeyMonitor = monitor
        do {
            try monitor.start()
            print("[DEBUG] HotkeyMonitor started — double-tap Ctrl to test")
        } catch {
            print("[DEBUG] HotkeyMonitor.start() failed: \(error)")
            return
        }
        hotkeyTask = Task { [weak monitor] in
            guard let stream = monitor?.events else { return }
            for await event in stream {
                print("[DEBUG] HotkeyEvent: \(event)")
            }
        }
    }
#endif
}
