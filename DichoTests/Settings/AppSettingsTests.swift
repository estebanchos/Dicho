import Foundation
import Testing
@testable import Dicho

@Suite("AppSettings")
@MainActor
struct AppSettingsTests {

    private let suiteName = "com.dicho.tests.AppSettings"

    private func fresh() -> UserDefaults {
        let d = UserDefaults(suiteName: suiteName)!
        d.removePersistentDomain(forName: suiteName)
        return d
    }

    // MARK: - Defaults

    @Test("isRawMode defaults to false")
    func defaultIsRawMode() {
        #expect(AppSettings(defaults: fresh()).isRawMode == false)
    }

    @Test("hudStyle defaults to fullTranscript")
    func defaultHUDStyle() {
        #expect(AppSettings(defaults: fresh()).hudStyle == .fullTranscript)
    }

    @Test("hasCompletedOnboarding defaults to false")
    func defaultHasCompletedOnboarding() {
        #expect(AppSettings(defaults: fresh()).hasCompletedOnboarding == false)
    }

    // MARK: - Persistence

    @Test("isRawMode persists across instances")
    func isRawModeRoundTrip() {
        let d = fresh()
        AppSettings(defaults: d).isRawMode = true
        #expect(AppSettings(defaults: d).isRawMode == true)
    }

    @Test("hudStyle persists across instances")
    func hudStyleRoundTrip() {
        let d = fresh()
        AppSettings(defaults: d).hudStyle = .waveformOnly
        #expect(AppSettings(defaults: d).hudStyle == .waveformOnly)
    }

    @Test("hasCompletedOnboarding persists across instances")
    func hasCompletedOnboardingRoundTrip() {
        let d = fresh()
        AppSettings(defaults: d).hasCompletedOnboarding = true
        #expect(AppSettings(defaults: d).hasCompletedOnboarding == true)
    }
}
