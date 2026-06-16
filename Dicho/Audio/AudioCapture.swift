import AVFoundation
import Speech

/// Production implementation of `AudioCapturing`.
///
/// Owns an `AVAudioEngine` that taps the default input node, converts each
/// `AVAudioPCMBuffer` to the format SpeechAnalyzer requires, and yields
/// `AnalyzerInput` values to the shared `analyzerContinuation`.
///
/// - Note: `@unchecked Sendable` — all mutable state is guarded by `stateLock`
///   or accessed only from the audio engine's tap queue, which is always the
///   same serial background queue per engine instance.
final class AudioCapture: AudioCapturing, @unchecked Sendable {

    // MARK: - AudioCapturing

    var errors: AsyncStream<AudioCaptureError> { errorStream }

    func startCapture() throws {
        guard !isRunning else { return }

        // `permissionMissing` (not `permissionRevoked`): the latter is reserved
        // for the user revoking access mid-session and is emitted via the
        // `errors` stream, not thrown from `startCapture()`.
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw AudioCaptureError.permissionMissing
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)

        // Determine the converter if the mic's native format differs from what
        // SpeechAnalyzer requested. Falls back to native if no target was set yet.
        let targetFmt = targetFormat ?? nativeFormat
        let converter: AVAudioConverter?
        if nativeFormat != targetFmt {
            converter = AVAudioConverter(from: nativeFormat, to: targetFmt)
        } else {
            converter = nil
        }

        let continuation = analyzerContinuation

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, _ in
            guard let self, self.isRunning else { return }

            let outBuffer: AVAudioPCMBuffer
            if let converter, let converted = Self.convert(buffer, using: converter, to: targetFmt) {
                outBuffer = converted
            } else {
                outBuffer = buffer
            }
            continuation?.yield(AnalyzerInput(buffer: outBuffer))
        }

        try engine.start()
        self.engine = engine
        isRunning = true
    }

    func stopCapture() {
        guard isRunning else { return }
        isRunning = false
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        analyzerContinuation?.finish()
        analyzerContinuation = nil
    }

    // MARK: - Internal (non-protocol) surface used by TranscriptionEngine

    /// Called by TranscriptionEngine before each session to register the new stream.
    func beginSession(continuation: AsyncStream<AnalyzerInput>.Continuation, format: AVAudioFormat) {
        analyzerContinuation = continuation
        targetFormat = format
    }

    // MARK: - Private

    private let errorStream: AsyncStream<AudioCaptureError>
    private let errorContinuation: AsyncStream<AudioCaptureError>.Continuation

    private var engine: AVAudioEngine?
    private var isRunning = false
    private var analyzerContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private(set) var targetFormat: AVAudioFormat?

    init() {
        (errorStream, errorContinuation) = AsyncStream.makeStream(of: AudioCaptureError.self)
    }

    private static func convert(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let frameCapacity = AVAudioFrameCount(
            Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate
        )
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
            return nil
        }
        var error: NSError?
        var consumed = false
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil ? out : nil
    }
}
