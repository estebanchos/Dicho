import AVFoundation
import Speech

/// Production implementation of `TranscriptionEngineProtocol`.
///
/// Uses `SpeechAnalyzer` + `SpeechTranscriber` (macOS 26, on-device).
/// Couples to `AudioCapture` at the implementation level — before each session,
/// `start()` asks `AudioCapture` for the session's `AnalyzerInput` stream and
/// registers the correct audio format.
///
/// Stream lifecycle: `start()` creates a fresh `updates` stream for each session;
/// `stop()` finalizes the analyzer, waits for all results, then finishes the stream.
/// The coordinator's transcript task exits naturally when the stream ends.
///
/// - Note: `@unchecked Sendable` — mutable state is guarded by actor isolation
///   (`start`/`stop` are always called from `@MainActor` via the coordinator).
///   `analyzerTask`/`resultTask` are written only on the caller's actor.
final class TranscriptionEngine: TranscriptionEngineProtocol, @unchecked Sendable {

    // MARK: - TranscriptionEngineProtocol

    var updates: AsyncStream<TranscriptUpdate> { updateStream }

    func start() async throws {
        // Create a fresh updates stream for this session.
        (updateStream, updateContinuation) = AsyncStream.makeStream(of: TranscriptUpdate.self)

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

        // Explicit options instead of .progressiveTranscription: that preset bundles
        // fastResults, which trades accuracy for latency ("faster but also less
        // accurate results" — smaller context window, per Apple docs). Dictation
        // inserts the FINAL transcript, so accuracy wins; volatileResults alone
        // keeps the live HUD text. (OPTIMIZATIONS.md #4, folded into M9.)
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )

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
                    continuation?.yield(TranscriptUpdate(text: text, range: nil, isFinal: result.isFinal))
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
        // Capture the active continuation before any suspension point.
        // If start() runs concurrently (cancel path fire-and-forget), this ensures
        // we finish the OLD session's stream, not the new one.
        let savedContinuation = updateContinuation

        // Let analyzeSequence drain the already-finished audio stream naturally.
        // This must complete before finalizeAndFinishThroughEndOfInput() is called;
        // otherwise the analyzer waits for a new input sequence that never arrives.
        if let task = analyzerTask { await task.value }
        analyzerTask = nil

        // Finalize: converts all in-flight volatile results to final results and
        // terminates the transcriber.results stream.
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        analyzer = nil

        // Wait for resultTask to deliver all final results to the updates continuation.
        // The coordinator's transcriptTask runs during this await (same @MainActor) and
        // processes the yielded updates into accumulatedTranscript.
        if let task = resultTask { await task.value }
        resultTask = nil
        transcriber = nil

        // Signal end of this session's updates stream so the coordinator's
        // transcriptTask exits naturally after draining any remaining buffered results.
        savedContinuation?.finish()
    }

    // MARK: - Private

    private var updateStream: AsyncStream<TranscriptUpdate>
    private var updateContinuation: AsyncStream<TranscriptUpdate>.Continuation?

    // Held unowned — AudioCapture outlives any single session.
    private unowned let audioCapture: AudioCapture

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var analyzerTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?

    init(audioCapture: AudioCapture) {
        self.audioCapture = audioCapture
        // Placeholder stream; replaced by a fresh one on each start() call.
        (updateStream, _) = AsyncStream.makeStream(of: TranscriptUpdate.self)
        updateContinuation = nil
    }
}
