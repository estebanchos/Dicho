import Foundation
@testable import Dicho

@MainActor
final class FakeAudioCapture: AudioCapturing {
    let errors: AsyncStream<AudioCaptureError>
    private let errorContinuation: AsyncStream<AudioCaptureError>.Continuation

    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    /// When non-nil, `startCapture()` throws this error instead of succeeding.
    var startError: AudioCaptureError?

    init() {
        var cont: AsyncStream<AudioCaptureError>.Continuation!
        errors = AsyncStream { cont = $0 }
        errorContinuation = cont
    }

    func startCapture() throws {
        if let error = startError { throw error }
        startCallCount += 1
    }

    func stopCapture() {
        stopCallCount += 1
    }

    /// Simulates a mid-recording device loss or permission revocation.
    func emitError(_ error: AudioCaptureError = .deviceLost) {
        errorContinuation.yield(error)
    }
}
