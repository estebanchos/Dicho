import Foundation
import ServiceManagement
import Observation

/// User-configurable application settings, persisted to UserDefaults.
///
/// Injected into `HUDPresenter` and observed by `AppDelegate` to keep
/// `DictationCoordinator.isRawMode` in sync whenever the user changes the setting.
@Observable
@MainActor
final class AppSettings {

    private enum Key {
        static let isRawMode              = "isRawMode"
        static let hudStyle               = "hudStyle"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
    }

    private let defaults: UserDefaults

    /// Bypass Foundation Models cleanup; insert the raw transcript verbatim.
    var isRawMode: Bool {
        didSet { defaults.set(isRawMode, forKey: Key.isRawMode) }
    }

    /// Controls how much the HUD shows during a recording session.
    var hudStyle: HUDStyle {
        didSet { defaults.set(hudStyle.rawValue, forKey: Key.hudStyle) }
    }

    /// True once the user dismisses the onboarding checklist via "Get Started".
    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding) }
    }

    /// Registers / unregisters Dicho as a login item via `SMAppService`.
    /// The stored value is initialised from the current service status.
    var launchAtLogin: Bool {
        didSet {
            if launchAtLogin {
                try? SMAppService.mainApp.register()
            } else {
                try? SMAppService.mainApp.unregister()
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isRawMode              = defaults.bool(forKey: Key.isRawMode)
        hudStyle               = HUDStyle(rawValue: defaults.string(forKey: Key.hudStyle) ?? "") ?? .fullTranscript
        hasCompletedOnboarding = defaults.bool(forKey: Key.hasCompletedOnboarding)
        launchAtLogin          = SMAppService.mainApp.status == .enabled
    }
}

/// How much the HUD shows while recording.
enum HUDStyle: String, CaseIterable, Identifiable {
    case fullTranscript
    case waveformOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fullTranscript: "Full transcript"
        case .waveformOnly:   "Icon only"
        }
    }
}
