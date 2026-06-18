import AVFoundation
import ApplicationServices
import Speech
import SwiftUI

/// SwiftUI content for the Settings window (shown via the status-item menu).
/// Receives the shared `AppSettings` instance so changes take effect immediately
/// in the running pipeline without requiring a relaunch.
struct SettingsView: View {

    @Bindable var settings: AppSettings

    @State private var micGranted = false
    @State private var axGranted = false
    @State private var modelReady: Bool? = nil  // nil = checking

    var body: some View {
        Form {
            Section("HUD") {
                Picker("Style", selection: $settings.hudStyle) {
                    ForEach(HUDStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.inline)
            }

            Section("Dictation") {
                Toggle("Raw mode (skip cleanup)", isOn: $settings.isRawMode)
                    .help("Insert the raw transcript without Foundation Models cleanup.")
            }

            Section("System") {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
            }

            Section("Permissions") {
                permissionRow(
                    label: "Microphone",
                    icon: "mic.fill",
                    granted: micGranted,
                    actionLabel: "Allow",
                    action: requestMicrophone
                )
                permissionRow(
                    label: "Accessibility",
                    icon: "hand.raised.fill",
                    granted: axGranted,
                    actionLabel: "Open Settings",
                    action: openAccessibilitySettings
                )
                modelRow
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .padding(.vertical)
        .task {
            refreshPermissions()
            await refreshModelStatus()
            // Re-check whenever the user returns from System Settings.
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                refreshPermissions()
                await refreshModelStatus()
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func permissionRow(
        label: String,
        icon: String,
        granted: Bool,
        actionLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            Label(label, systemImage: icon)
            Spacer()
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button(actionLabel, action: action)
                    .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private var modelRow: some View {
        HStack {
            Label("Speech Model", systemImage: "waveform")
            Spacer()
            if let ready = modelReady {
                if ready {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Button("Enable Apple Intelligence") { openAppleIntelligenceSettings() }
                        .buttonStyle(.bordered)
                }
            } else {
                ProgressView().scaleEffect(0.75)
            }
        }
    }

    // MARK: - Permission helpers

    private func refreshPermissions() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        axGranted = AXIsProcessTrustedWithOptions(nil)
    }

    private func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { micGranted = granted }
        }
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openAppleIntelligenceSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.AppleIntelligence") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Model status (read-only — download is the pipeline's responsibility)

    private func refreshModelStatus() async {
        modelReady = nil
        // installedLocales only lists models already on-device; no locale reservations or
        // other side-effects. assetInstallationRequest is not used here because it reserves
        // locales automatically and returns non-nil even for an already-installed model when
        // the app hasn't reserved that locale yet in the current session.
        let installed = await SpeechTranscriber.installedLocales
        guard !installed.isEmpty else {
            modelReady = false
            return
        }
        let preferred = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
        let fallback  = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
        guard let target = preferred ?? fallback else {
            modelReady = false
            return
        }
        modelReady = installed.contains(target)
    }
}
