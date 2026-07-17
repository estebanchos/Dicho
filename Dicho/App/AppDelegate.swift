import AppKit
import AVFoundation
import SwiftUI

/// Application delegate. Owns the status item, shared `AppSettings`, and the full
/// dictation pipeline. `AppSettings` is created first so it can be injected into
/// both the pipeline and the SwiftUI Settings/Onboarding windows.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private(set) var settings = AppSettings()

    private var statusItem: NSStatusItem?

    // Pipeline — held for lifecycle management
    private var audioCapture: AudioCapture?
    private var transcriptionEngine: TranscriptionEngine?
    private var coordinator: DictationCoordinator?
    private var hudPresenter: HUDPresenter?
    private var onboardingController: OnboardingWindowController?
    private lazy var settingsScene = NSHostingSceneRepresentation {
        Settings {
            SettingsView(settings: self.settings)
        }
    }

    private var accessibilityPollTimer: Timer?

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

#if DEBUG
        // M12 eval harness: eval runs host the test bundle inside this app
        // process (TEST_HOST) with DICHO_EVAL=1 forwarded by xcodebuild. Skip
        // the status item, onboarding, permission flow, and pipeline so the
        // app's own hotkey tap and mic request stay quiet — the harness builds
        // its own pipeline graph. See Documentation/eval_harness_plan.md.
        if ProcessInfo.processInfo.environment["DICHO_EVAL"] == "1" {
            print("[DEBUG] DICHO_EVAL=1 — skipping app pipeline launch for eval run")
            return
        }
#endif

        setupStatusItem()

        onboardingController = OnboardingWindowController(settings: settings)

        requestMicPermission()

        if shouldShowOnboarding() {
            onboardingController?.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stopListening()
        accessibilityPollTimer?.invalidate()
    }

    // MARK: - Onboarding gate

    private func shouldShowOnboarding() -> Bool {
        if !settings.hasCompletedOnboarding { return true }
        let micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let axOK  = AXIsProcessTrustedWithOptions(nil)
        return !micOK || !axOK
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }
        // Dicho logo (shield + quotes) as a template image so the menu bar tints
        // it for light/dark automatically. Sized to the standard menu-bar glyph.
        let icon = NSImage(named: "MenuBarIcon")
        icon?.isTemplate = true
        icon?.size = NSSize(width: 18, height: 18)
        button.image = icon

        let menu = NSMenu()
        menu.delegate = self

        let dictationItem = NSMenuItem(title: "Start Dictation", action: #selector(toggleDictation), keyEquivalent: "")
        dictationItem.target = self
        dictationItem.tag = 1
        menu.addItem(dictationItem)

        let rawItem = NSMenuItem(title: "Raw Mode", action: #selector(toggleRawMode), keyEquivalent: "")
        rawItem.target = self
        rawItem.tag = 2
        menu.addItem(rawItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Dicho", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    // MARK: - Menu actions

    @objc private func toggleDictation() {
        guard let coordinator else { return }
        Task {
            switch coordinator.state {
            case .idle:      await coordinator.handleHotkeyEvent(.startRequested)
            case .recording: await coordinator.handleHotkeyEvent(.stopRequested)
            default: break
            }
        }
    }

    @objc private func toggleRawMode() {
        settings.isRawMode.toggle()
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        settingsScene.environment.openSettings()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Pipeline startup

    /// Requests the mic permission OS prompt (if undetermined) and proceeds to the
    /// Accessibility check regardless of the result.
    private func requestMicPermission() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
#if DEBUG
                if !granted {
                    print("[DEBUG] Microphone permission not granted — pipeline still starting")
                }
#endif
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
        // If onboarding is showing it will guide the user; we still poll as a fallback.
#if DEBUG
        print("[DEBUG] Accessibility not granted — waiting (onboarding should guide the user).")
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

    /// Assembles all production types, starts the coordinator, and begins observing
    /// state so the status-item icon and menu stay in sync.
    private func launchPipeline() {
        let audio        = AudioCapture()
        let transcription = TranscriptionEngine(audioSource: audio)
        let coordinator  = DictationCoordinator(
            hotkeyMonitor: HotkeyMonitor(),
            audioCapture: audio,
            transcriptionEngine: transcription,
            cleanupService: CleanupService(),
            textInserter: TextInserter(),
            rescoringService: RescoringService(),
            activeAppProvider: ActiveAppProvider(),
            isRawMode: settings.isRawMode
        )

        self.audioCapture       = audio
        self.transcriptionEngine = transcription
        self.coordinator        = coordinator
        self.hudPresenter       = HUDPresenter(coordinator: coordinator, settings: settings)

        coordinator.startListening()
        scheduleObservation()

#if DEBUG
        print("[DEBUG] Dicho M7 pipeline running — double-tap Ctrl to dictate (target-app context active)")
#endif
    }

    // MARK: - Observation

    /// Recursively tracks `settings.isRawMode` and `coordinator.activeNotice` so
    /// settings changes propagate to the coordinator and Accessibility revocation
    /// reopens onboarding — without coupling the two directly. The status-item
    /// icon is the static Dicho logo (recording state is shown by the HUD), so it
    /// is no longer swapped here.
    private func scheduleObservation() {
        guard let coordinator else { return }
        withObservationTracking {
            // Keep coordinator's raw-mode flag in sync with settings.
            coordinator.isRawMode = settings.isRawMode

            // Open onboarding if the event tap signals Accessibility was revoked.
            if coordinator.activeNotice == .accessibilityPermissionMissing {
                onboardingController?.show()
            }
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.scheduleObservation() }
        }
    }
}

// MARK: - NSMenuDelegate

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        // Update Start/Stop title to reflect current pipeline state.
        if let item = menu.item(withTag: 1) {
            let isRecording = coordinator?.state == .recording
            item.title = isRecording ? "Stop Dictation" : "Start Dictation"
            item.isEnabled = coordinator != nil
        }

        // Update Raw Mode checkmark.
        if let item = menu.item(withTag: 2) {
            item.state = settings.isRawMode ? .on : .off
        }
    }
}
