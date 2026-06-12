import Foundation
@testable import Dicho

@MainActor
final class FakeHotkeyMonitor: HotkeyMonitoring {
    let events: AsyncStream<HotkeyEvent>
    private let continuation: AsyncStream<HotkeyEvent>.Continuation

    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    var shouldThrowOnStart = false

    init() {
        var cont: AsyncStream<HotkeyEvent>.Continuation!
        events = AsyncStream { cont = $0 }
        continuation = cont
    }

    func start() throws {
        if shouldThrowOnStart { throw HotkeyMonitorError.accessibilityNotGranted }
        startCallCount += 1
    }

    func stop() {
        stopCallCount += 1
        continuation.finish()
    }

    func emit(_ event: HotkeyEvent) {
        continuation.yield(event)
    }
}

enum HotkeyMonitorError: Error {
    case accessibilityNotGranted
}
