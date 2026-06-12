import AVFoundation
import Speech

/// Production implementation of `TranscriptionEngineProtocol`.
///
/// Uses `SpeechAnalyzer` + `SpeechTranscriber` (macOS 26, on-device).
/// Couples to `AudioCapture` at the implementation level — before each session,
/// `start()` asks `AudioCapture` for the session's `AnalyzerInput` stream and
/// registers the correct audio format.
///
/// - Note: `@unchecked Sendable` — mutable state is guarded by actor isolation
///   (`start`/`stop` are `async`), and `analyzerTask`/`resultTask` are only
///   written on the caller's task, which is always `@MainActor` via the coordinator.
final class TranscriptionEngine: TranscriptionEngineProtocol, @unchecked Sendable {

    // MARK: - TranscriptionEngineProtocol

    var updates: AsyncStream<TranscriptUpdate> { updateStream }

    func start() async throws {
        let transcriber = SpeechTranscriber(
            locale: Locale(identifier: "en-US"),
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )

        // Ensure assets are installed; download if needed.
        if let request = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber],
            considering: audioCapture.targetFormat
        ) else {
            throw AudioCaptureError.deviceLost
        }

        // Give AudioCapture the new session continuation and the required format.
        let (analyzerStream, analyzerContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        audioCapture.beginSession(continuation: analyzerContinuation, format: format)

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        self.transcriber = transcriber

        // Feed audio to the analyzer autonomously.
        analyzerTask = Task {
            _ = try? await analyzer.analyzeSequence(analyzerStream)
        }

        // Consume results and map to TranscriptUpdate.
        let continuation = updateContinuation
        resultTask = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    continuation.yield(TranscriptUpdate(text: text, range: nil, isFinal: result.isFinal))
                }
            } catch {
                // Result stream ended — normal on stop.
            }
        }
    }

    func stop() async {
        analyzerTask?.cancel()
        analyzerTask = nil
        resultTask?.cancel()
        resultTask = nil
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        analyzer = nil
        transcriber = nil
    }

    // MARK: - Private

    private let updateStream: AsyncStream<TranscriptUpdate>
    private let updateContinuation: AsyncStream<TranscriptUpdate>.Continuation

    // Held unowned — AudioCapture outlives any single session.
    private unowned let audioCapture: AudioCapture

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var analyzerTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?

    init(audioCapture: AudioCapture) {
        self.audioCapture = audioCapture
        (updateStream, updateContinuation) = AsyncStream.makeStream(of: TranscriptUpdate.self)
    }
}
