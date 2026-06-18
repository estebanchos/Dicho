import AVFoundation
import ApplicationServices
import Speech
import SwiftUI

/// Onboarding checklist shown on first launch or when a required permission is missing.
/// Checks Microphone, Accessibility, and Speech Model status; surfaces action buttons
/// for each. "Get Started" is enabled only when all three are green.
struct OnboardingView: View {

    let settings: AppSettings
    var onComplete: @MainActor () -> Void

    @State private var micStatus: ItemStatus = .checking
    @State private var axStatus: ItemStatus  = .checking
    @State private var modelStatus: ItemStatus = .checking

    enum ItemStatus { case checking, ready, actionRequired }

    private var allReady: Bool {
        micStatus == .ready && axStatus == .ready && modelStatus == .ready
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to Dicho")
                    .font(.largeTitle.bold())
                Text("Grant these permissions before you start dictating.")
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 24)

            // Checklist
            VStack(spacing: 0) {
                row(
                    icon: "mic.fill", iconColor: .blue,
                    title: "Microphone",
                    detail: "Captures your voice for on-device transcription.",
                    status: micStatus,
                    action: requestMicrophone
                )
                Divider().padding(.leading, 52)
                row(
                    icon: "hand.raised.fill", iconColor: .purple,
                    title: "Accessibility",
                    detail: "Detects the double-tap hotkey and inserts text at the cursor.",
                    status: axStatus,
                    action: openAccessibilitySettings
                )
                Divider().padding(.leading, 52)
                row(
                    icon: "waveform", iconColor: .orange,
                    title: "Speech Model",
                    detail: "On-device transcription model — no audio leaves your Mac.",
                    status: modelStatus,
                    action: nil
                )
            }
            .background(.quinary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.bottom, 24)

            // Footer
            HStack {
                Spacer()
                Button("Get Started") {
                    settings.hasCompletedOnboarding = true
                    onComplete()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!allReady)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(32)
        .frame(width: 540)
        .task { await refreshAll() }
    }

    // MARK: - Row builder

    @ViewBuilder
    private func row(
        icon: String, iconColor: Color,
        title: String, detail: String,
        status: ItemStatus,
        action: (() -> Void)?
    ) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(iconColor)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            switch status {
            case .ready:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
            case .checking:
                ProgressView().scaleEffect(0.75)
            case .actionRequired:
                if let action {
                    Button(title == "Microphone" ? "Allow" : "Open Settings", action: action)
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Refresh

    private func refreshAll() async {
        refreshMic()
        refreshAccessibility()
        await checkSpeechModel()
    }

    private func refreshMic() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:               micStatus = .ready
        case .notDetermined:            micStatus = .actionRequired
        case .denied, .restricted:      micStatus = .actionRequired
        @unknown default:               micStatus = .actionRequired
        }
    }

    private func refreshAccessibility() {
        axStatus = AXIsProcessTrustedWithOptions(nil) ? .ready : .actionRequired
    }

    private func checkSpeechModel() async {
        let preferred = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
        let fallback  = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
        guard let locale = preferred ?? fallback else {
            modelStatus = .actionRequired
            return
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if let request = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            modelStatus = .checking
            do {
                try await request.downloadAndInstall()
                modelStatus = .ready
            } catch {
                modelStatus = .actionRequired
            }
        } else {
            modelStatus = .ready
        }
    }

    // MARK: - Actions

    private func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { self.micStatus = granted ? .ready : .actionRequired }
        }
    }

    private func openAccessibilitySettings() {
        // swiftlint:disable:next force_unwrapping
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        // Poll until granted so the row updates without requiring a manual refresh.
        Task {
            while !AXIsProcessTrustedWithOptions(nil) {
                try? await Task.sleep(for: .seconds(1))
            }
            axStatus = .ready
        }
    }
}
