import SwiftUI

/// SwiftUI content for the Settings window (shown via the status-item menu).
/// Receives the shared `AppSettings` instance so changes take effect immediately
/// in the running pipeline without requiring a relaunch.
struct SettingsView: View {

    @Bindable var settings: AppSettings

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
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .padding(.vertical)
    }
}
