import Foundation
@testable import Dicho

/// Test double for `ActiveAppProviding`. Returns a stubbed `AppContext?` and
/// counts invocations so coordinator tests can assert capture-at-stop-time
/// behavior without touching `NSWorkspace`.
@MainActor
final class FakeActiveAppProvider: ActiveAppProviding {
    var stubbedContext: AppContext? = nil
    private(set) var currentAppCallCount = 0

    func currentApp() -> AppContext? {
        currentAppCallCount += 1
        return stubbedContext
    }
}
