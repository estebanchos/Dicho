import AVFoundation
import ApplicationServices
import SwiftUI

/// SwiftUI content for the Settings window (shown via the status-item menu).
/// Receives the shared `AppSettings` instance so changes take effect immediately
/// in the running pipeline without requiring a relaunch.
struct SettingsView: View {

    @Bindable var settings: AppSettings

    @State private var micGranted = false
    @State private var axGranted = false

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
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .padding(.vertical)
        .task {
            refreshPermissions()
            // Re-check whenever the user returns from System Settings.
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                refreshPermissions()
            }
        }
    }

    // MARK: - Row

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
}
