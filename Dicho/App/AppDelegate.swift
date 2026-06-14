import AppKit
import AVFoundation

/// Application delegate. Owns the status item and the full dictation pipeline.
/// Assembled here so `DictationCoordinator` and all production collaborators share
/// the same lifetime as the process.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?

    // Pipeline — held for lifecycle management
    private var audioCapture: AudioCapture?
    private var transcriptionEngine: TranscriptionEngine?
    private var coordinator: DictationCoordinator?
    private var hudPresenter: HUDPresenter?

    private var accessibilityPollTimer: Timer?

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        requestMicPermission()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stopListening()
        accessibilityPollTimer?.invalidate()
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

    // MARK: - Pipeline startup

    /// Requests mic access; on grant proceeds to Accessibility check → pipeline launch.
    private func requestMicPermission() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard granted else {
#if DEBUG
                    print("[DEBUG] Microphone permission denied — pipeline not started")
#endif
                    return
                }
                self?.checkAccessibilityThenLaunch()
            }
        }
    }

    /// Checks Accessibility trust (needed for CGEventTap). If not yet granted,
    /// opens System Settings and polls until the user enables it, then launches.
    private func checkAccessibilityThenLaunch() {
        if AXIsProcessTrustedWithOptions(nil) {
            launchPipeline()
            return
        }
        NSWorkspace.shared.open(
            // swiftlint:disable:next force_unwrapping
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        )
#if DEBUG
        print("[DEBUG] Accessibility not granted — System Settings opened.")
        print("[DEBUG] Add \(Bundle.main.bundlePath) and enable the toggle.")
#endif
        accessibilityPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, AXIsProcessTrustedWithOptions(nil) else { return }
                self.accessibilityPollTimer?.invalidate()
                self.accessibilityPollTimer = nil
                self.launchPipeline()
            }
        }
    }

    /// Assembles all production types and starts the coordinator.
    ///
    /// `isRawMode: true` continues to bypass cleanup until `CleanupService` is
    /// implemented in M5. `TextInserter` is the real pasteboard + Cmd+V impl
    /// from M4; the raw transcript pastes at the cursor on stop.
    private func launchPipeline() {
        let audio = AudioCapture()
        let transcription = TranscriptionEngine(audioCapture: audio)
        let coordinator = DictationCoordinator(
            hotkeyMonitor: HotkeyMonitor(),
            audioCapture: audio,
            transcriptionEngine: transcription,
            cleanupService: CleanupService(),
            textInserter: TextInserter(),
            isRawMode: true
        )

        self.audioCapture = audio
        self.transcriptionEngine = transcription
        self.coordinator = coordinator
        self.hudPresenter = HUDPresenter(coordinator: coordinator)

        coordinator.startListening()

#if DEBUG
        print("[DEBUG] Dicho M4 pipeline running — double-tap Ctrl to dictate")
#endif
    }
}
