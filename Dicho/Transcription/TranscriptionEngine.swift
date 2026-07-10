import AVFoundation
import Speech

/// Production implementation of `TranscriptionEngineProtocol`.
///
/// Uses `SpeechAnalyzer` + `SpeechTranscriber` (macOS 26, on-device).
/// Receives audio through the `AnalyzerAudioSource` seam (M12) — before each
/// session, `start()` creates the session's `AnalyzerInput` stream and
/// registers its continuation + the required audio format with the source
/// (production: `AudioCapture`; eval harness: `FileAudioCapture`).
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
        // alternativeTranscriptions + transcriptionConfidence feed the M10
        // rescoring gate; the C0 spike (2026-07-06) verified all three options
        // coexist — volatile updates keep flowing, finals carry alternatives.
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .alternativeTranscriptions],
            attributeOptions: [.transcriptionConfidence]
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

        // Give the audio source the new session continuation and the required format.
        let (analyzerStream, analyzerContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        audioSource.beginSession(continuation: analyzerContinuation, format: format)

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
                    // Alternatives and confidence are meaningful on finals only:
                    // volatile results carry a single echo alternative and no
                    // confidence attribute (C0 spike, 2026-07-06).
                    let alternatives = result.isFinal
                        ? result.alternatives.map { String($0.characters) }
                        : []
                    let confidence = result.isFinal
                        ? Self.minimumConfidence(in: result.text)
                        : nil
#if DEBUG
                    print("[DEBUG] TranscriptionEngine: result isFinal=\(result.isFinal) text='\(text)' confidence=\(confidence.map { String(format: "%.2f", $0) } ?? "nil")")
                    if result.isFinal && alternatives.count > 1 {
                        // Manual A/B aid (10.6): show the full candidate list so the
                        // kill-criterion check can see whether the correct word was
                        // available to the selector.
                        for (i, alt) in alternatives.enumerated() {
                            print("[DEBUG]   candidate \(i): '\(alt)'")
                        }
                    }
#endif
                    continuation?.yield(TranscriptUpdate(
                        text: text,
                        range: nil,
                        isFinal: result.isFinal,
                        alternatives: alternatives,
                        confidence: confidence
                    ))
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

    // MARK: - Internal — exposed for unit tests (pure, no live Speech calls)

    /// The lowest per-run `transcriptionConfidence` in an attributed
    /// transcription result, or nil when no run carries the attribute
    /// (volatile results never do; finals always did in the C0 spike).
    /// The minimum is the rescoring-gate signal: one uncertain word makes
    /// the whole segment a rescoring candidate.
    static func minimumConfidence(in text: AttributedString) -> Double? {
        var minimum: Double?
        for (value, _) in text.runs[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self] {
            guard let value else { continue }
            minimum = min(minimum ?? value, value)
        }
        return minimum
    }

    // MARK: - Private

    private var updateStream: AsyncStream<TranscriptUpdate>
    private var updateContinuation: AsyncStream<TranscriptUpdate>.Continuation?

    // Held unowned — the audio source outlives any single session (the app
    // delegate / eval harness owns it for the pipeline's lifetime).
    private unowned let audioSource: any AnalyzerAudioSource

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var analyzerTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?

    init(audioSource: any AnalyzerAudioSource) {
        self.audioSource = audioSource
        // Placeholder stream; replaced by a fresh one on each start() call.
        (updateStream, _) = AsyncStream.makeStream(of: TranscriptUpdate.self)
        updateContinuation = nil
    }
}
