import AVFoundation
import Speech
@testable import Dicho

/// Pure pacing math for `FileAudioCapture` — unit-tested in the normal gate
/// (`FileAudioCapturePacingTests`), no audio I/O involved.
enum PacingSchedule {
    /// Wall-clock offset from stream start at which feeding may proceed AFTER
    /// `frames` frames have been yielded. Computed from the running TOTAL, not
    /// by summing per-chunk durations, so floating-point error cannot
    /// accumulate as pacing drift over a long fixture.
    static func offset(afterFrames frames: Int64, sampleRate: Double) -> Duration {
        .seconds(Double(frames) / sampleRate)
    }

    /// Frame count for a trailing-silence tail at the given sample rate.
    static func silenceFrames(duration: TimeInterval, sampleRate: Double) -> Int {
        max(0, Int((duration * sampleRate).rounded()))
    }
}

/// Eval-only audio source (M12.3): feeds a fixture audio file through the
/// production `TranscriptionEngine` at 1× wall-clock pace, standing in for the
/// microphone. Conforms to both pipeline seams:
/// - `AnalyzerAudioSource` — receives the engine's continuation + format,
/// - `AudioCapturing` — the coordinator starts/stops it like the real mic.
///
/// Behavior: `startCapture()` reads the file in ~4096-frame chunks (matching
/// the production tap buffer size), converts each to the analyzer's format via
/// `AVAudioConverter` (same single-shot pattern as `AudioCapture.convert`),
/// yields `AnalyzerInput`s paced to a total-based wall-clock schedule, appends
/// `trailingSilence` of zeroed audio (the beat between the last word and the
/// user's stop tap), finishes the continuation, and fires `onPlaybackFinished`
/// — the runner's cue to record `tStop` and send `.stopRequested`.
///
/// The `errors` stream never yields: fixture files don't lose devices. A file
/// that cannot be opened throws from `startCapture()` (surfaces as
/// `.audioCaptureFailed` in the coordinator — a loud harness failure).
///
/// - Note: `@unchecked Sendable` — `analyzerContinuation` / `targetFormat` /
///   `feedTask` are written only on the MainActor (`beginSession` from the
///   engine, `startCapture`/`stopCapture` from the coordinator, all
///   MainActor-isolated call sites); the feed task operates on immutable local
///   copies captured at spawn.
final class FileAudioCapture: AudioCapturing, AnalyzerAudioSource, @unchecked Sendable {

    /// Fired exactly once, after EOF + trailing silence have been fed and the
    /// analyzer stream finished. May fire on a background executor.
    var onPlaybackFinished: (@Sendable () -> Void)?

    private let fileURL: URL
    private let trailingSilence: TimeInterval
    private let chunkFrames: AVAudioFrameCount = 4_096

    private var analyzerContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var targetFormat: AVAudioFormat?
    private var feedTask: Task<Void, Never>?

    private let errorStream: AsyncStream<AudioCaptureError>
    private let errorContinuation: AsyncStream<AudioCaptureError>.Continuation

    init(fileURL: URL, trailingSilence: TimeInterval = 0.3) {
        self.fileURL = fileURL
        self.trailingSilence = trailingSilence
        (errorStream, errorContinuation) = AsyncStream.makeStream(of: AudioCaptureError.self)
    }

    // MARK: - AnalyzerAudioSource

    func beginSession(continuation: AsyncStream<AnalyzerInput>.Continuation, format: AVAudioFormat) {
        analyzerContinuation = continuation
        targetFormat = format
    }

    // MARK: - AudioCapturing

    var errors: AsyncStream<AudioCaptureError> { errorStream }

    func startCapture() throws {
        guard let continuation = analyzerContinuation, let format = targetFormat else {
            // Ordering contract violated (engine.start() must run first).
            throw AudioCaptureError.deviceLost
        }
        let file = try AVAudioFile(forReading: fileURL)

        let chunkFrames = self.chunkFrames
        let trailingSilence = self.trailingSilence
        let finished = onPlaybackFinished
        feedTask = Task.detached(priority: .userInitiated) {
            Self.feed(
                file: file,
                to: continuation,
                format: format,
                chunkFrames: chunkFrames,
                trailingSilence: trailingSilence
            )
            continuation.finish()
            finished?()
        }
    }

    func stopCapture() {
        feedTask?.cancel()
        feedTask = nil
        analyzerContinuation?.finish()
        analyzerContinuation = nil
    }

    // MARK: - Feeding

    private static func feed(
        file: AVAudioFile,
        to continuation: AsyncStream<AnalyzerInput>.Continuation,
        format: AVAudioFormat,
        chunkFrames: AVAudioFrameCount,
        trailingSilence: TimeInterval
    ) {
        let sourceFormat = file.processingFormat
        let converter = sourceFormat == format ? nil : AVAudioConverter(from: sourceFormat, to: format)
        let clock = ContinuousClock()
        let start = clock.now
        var framesFed: Int64 = 0

        while !Task.isCancelled {
            guard let inBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: chunkFrames) else {
                break
            }
            do {
                try file.read(into: inBuffer, frameCount: chunkFrames)
            } catch {
                break
            }
            guard inBuffer.frameLength > 0 else { break } // EOF

            let outBuffer: AVAudioPCMBuffer
            if let converter, let converted = convert(inBuffer, using: converter, to: format) {
                outBuffer = converted
            } else {
                outBuffer = inBuffer
            }
            continuation.yield(AnalyzerInput(buffer: outBuffer))
            framesFed += Int64(inBuffer.frameLength)

            // 1× pacing: sleep until the wall-clock moment this much audio
            // would have existed in a live recording (total-based, drift-free).
            let deadline = start + PacingSchedule.offset(afterFrames: framesFed, sampleRate: sourceFormat.sampleRate)
            try? blockingSleep(of: clock, until: deadline)
        }

        if !Task.isCancelled, trailingSilence > 0,
           let silence = makeSilenceBuffer(format: format, duration: trailingSilence) {
            continuation.yield(AnalyzerInput(buffer: silence))
            let deadline = start
                + PacingSchedule.offset(afterFrames: framesFed, sampleRate: sourceFormat.sampleRate)
                + .seconds(trailingSilence)
            try? blockingSleep(of: clock, until: deadline)
        }
    }

    /// Synchronous sleep on the detached feed task's thread. The feed loop is
    /// deliberately synchronous (file reads + converter are blocking APIs);
    /// occupying one background thread for the fixture's duration is fine in
    /// the eval harness.
    private static func blockingSleep(of clock: ContinuousClock, until deadline: ContinuousClock.Instant) throws {
        let remaining = clock.now.duration(to: deadline)
        guard remaining > .zero else { return }
        let interval = Double(remaining.components.seconds)
            + Double(remaining.components.attoseconds) / 1e18
        Thread.sleep(forTimeInterval: interval)
    }

    /// A zeroed PCM buffer of `duration` seconds in the analyzer's format.
    /// Returns nil for non-float formats (not observed in practice — the
    /// analyzer's preferred format is float PCM); silence is then skipped.
    private static func makeSilenceBuffer(format: AVAudioFormat, duration: TimeInterval) -> AVAudioPCMBuffer? {
        let frames = PacingSchedule.silenceFrames(duration: duration, sampleRate: format.sampleRate)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<Int(format.channelCount) {
            channels[channel].update(repeating: 0, count: frames)
        }
        return buffer
    }

    /// Same single-shot conversion pattern as production `AudioCapture.convert`.
    private static func convert(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let frameCapacity = AVAudioFrameCount(
            Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate
        ) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
            return nil
        }
        // Mirrors production AudioCapture.convert: the SDK types the input
        // block as `@Sendable`, but it runs synchronously inside `convert`.
        final class Input: @unchecked Sendable {
            var consumed = false
            let buffer: AVAudioPCMBuffer
            init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        }
        let input = Input(buffer)
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if input.consumed {
                status.pointee = .noDataNow
                return nil
            }
            input.consumed = true
            status.pointee = .haveData
            return input.buffer
        }
        return error == nil ? out : nil
    }
}
