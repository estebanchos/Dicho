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
        // Resolve locale against installed assets so the transcriber can actually run.
        // Two separate awaits required — ?? right-hand side is @autoclosure (not async).
        let preferredLocale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
        let fallbackLocale  = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
        guard let locale = preferredLocale ?? fallbackLocale else {
            throw AudioCaptureError.deviceLost
        }
#if DEBUG
        print("[DEBUG] TranscriptionEngine using locale: \(locale.identifier)")
#endif

        // progressiveTranscription = volatileResults + fastResults — ideal for live dictation.
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)

        // Ensure assets are installed; download if needed.
        if let request = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
#if DEBUG
            print("[DEBUG] TranscriptionEngine: downloading speech assets…")
#endif
            try await request.downloadAndInstall()
        }

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber],
            considering: nil
        ) else {
            throw AudioCaptureError.deviceLost
        }
#if DEBUG
        print("[DEBUG] TranscriptionEngine: audio format = \(format)")
#endif

        // Give AudioCapture the new session continuation and the required format.
        let (analyzerStream, analyzerContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        audioCapture.beginSession(continuation: analyzerContinuation, format: format)

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        // Prewarm so the first result isn't delayed by lazy asset loading.
        try? await analyzer.prepareToAnalyze(in: format)

        self.analyzer = analyzer
        self.transcriber = transcriber

        // Feed audio to the analyzer. analyzeSequence returns when the stream finishes.
        analyzerTask = Task {
            do {
                _ = try await analyzer.analyzeSequence(analyzerStream)
#if DEBUG
                print("[DEBUG] TranscriptionEngine: analyzeSequence finished")
#endif
            } catch {
#if DEBUG
                print("[DEBUG] TranscriptionEngine: analyzeSequence error: \(error)")
#endif
            }
        }

        // Consume results and map to TranscriptUpdate.
        let continuation = updateContinuation
        resultTask = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
#if DEBUG
                    print("[DEBUG] TranscriptionEngine: result isFinal=\(result.isFinal) text='\(text)'")
#endif
                    continuation.yield(TranscriptUpdate(text: text, range: nil, isFinal: result.isFinal))
                }
#if DEBUG
                print("[DEBUG] TranscriptionEngine: results stream ended")
#endif
            } catch {
#if DEBUG
                print("[DEBUG] TranscriptionEngine: results error: \(error)")
#endif
            }
        }
    }

    func stop() async {
        resultTask?.cancel()
        resultTask = nil
        analyzerTask?.cancel()
        analyzerTask = nil
        // cancelAndFinishNow() terminates the session immediately — no waiting for
        // input to drain, so this never hangs even if analyzeSequence was cancelled.
        if let analyzer {
            await analyzer.cancelAndFinishNow()
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
