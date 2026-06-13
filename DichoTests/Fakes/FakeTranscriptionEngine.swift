import Foundation
@testable import Dicho

@MainActor
final class FakeTranscriptionEngine: TranscriptionEngineProtocol {

    // `updates` always returns the stream for the current session.
    // start() creates a fresh one; stop() finishes it.
    var updates: AsyncStream<TranscriptUpdate> { stream }
    private var stream: AsyncStream<TranscriptUpdate>
    private var continuation: AsyncStream<TranscriptUpdate>.Continuation

    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    var shouldThrowOnStart: Error? = nil
    /// If non-nil, emitted as a final update just before stop() finishes the stream.
    /// Simulates final results that the production engine delivers during finalization.
    var stubbedFinalTranscript: String? = nil

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: TranscriptUpdate.self)
    }

    func start() async throws {
        if let error = shouldThrowOnStart { throw error }
        startCallCount += 1
        // Create a fresh stream so each session has its own, isolated updates channel.
        (stream, continuation) = AsyncStream.makeStream(of: TranscriptUpdate.self)
    }

    func stop() async {
        stopCallCount += 1
        // Deliver any stubbed final transcript before closing the stream, mirroring
        // the production engine's finalization behaviour.
        if let text = stubbedFinalTranscript {
            continuation.yield(TranscriptUpdate(text: text, range: nil, isFinal: true))
        }
        continuation.finish()
    }

    func emit(_ update: TranscriptUpdate) {
        continuation.yield(update)
    }
}
