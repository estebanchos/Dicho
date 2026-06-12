import Foundation
@testable import Dicho

@MainActor
final class FakeTranscriptionEngine: TranscriptionEngineProtocol {
    let updates: AsyncStream<TranscriptUpdate>
    private let continuation: AsyncStream<TranscriptUpdate>.Continuation

    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    var shouldThrowOnStart: Error? = nil

    init() {
        var cont: AsyncStream<TranscriptUpdate>.Continuation!
        updates = AsyncStream { cont = $0 }
        continuation = cont
    }

    func start() async throws {
        if let error = shouldThrowOnStart { throw error }
        startCallCount += 1
    }

    func stop() async {
        stopCallCount += 1
    }

    func emit(_ update: TranscriptUpdate) {
        continuation.yield(update)
    }
}
