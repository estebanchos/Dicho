import AVFoundation
import Speech
@testable import Dicho

/// M17 eval-only second `TranscriptionEngineProtocol` conformer, used
/// exclusively by the env-gated ASR A/B runner (`AsrABRun.swift`, a separate
/// task). It drives `DictationTranscriber` — the system-dictation model
/// family — instead of production's `SpeechTranscriber`, so the eval can
/// answer whether the dictation model beats, ties, or loses to Dicho's
/// current flagship-model config (`Documentation/asr_ab_plan.md` §3.1–3.2).
///
/// This type deliberately duplicates `TranscriptionEngine`'s shape (locale
/// resolution → asset install → `bestAvailableAudioFormat` → `analyzeSequence`
/// → result mapping → `finalizeAndFinishThroughEndOfInput`) rather than
/// factoring out a shared base: the eval's validity depends on the two arms
/// differing in **exactly one variable** — the transcriber module — so every
/// other line (option shapes aside, per arm 2) must be a faithful mirror, and
/// this file must never influence production code paths. ~100 duplicated
/// lines is the accepted price for zero production changes before evidence
/// exists (asr_ab_plan.md §3.1). It ships only in the test target and is
/// never referenced from `Dicho/`.
///
/// `contextualStrings` is the arm-3 smoke-rider hook: `AnalysisContext`
/// biasing works only with `DictationTranscriber`, never `SpeechTranscriber`
/// (Apple forum thread 801877; OPTIMIZATIONS.md #11), so this is also a
/// mechanism check ahead of a future dedicated vocabulary milestone.
///
/// - Note: `@unchecked Sendable` — mutable state is guarded by actor
///   isolation, same as production: `start`/`stop` are always called from a
///   single actor context by the eval runner (never concurrently), and
///   `analyzerTask`/`resultTask` are written only on the caller's actor.
final class DictationEvalEngine: TranscriptionEngineProtocol, @unchecked Sendable {

    // MARK: - TranscriptionEngineProtocol

    var updates: AsyncStream<TranscriptUpdate> { updateStream }

    func start() async throws {
        // Create a fresh updates stream for this session.
        (updateStream, updateContinuation) = AsyncStream.makeStream(of: TranscriptUpdate.self)

        // Resolve locale against installed assets so the transcriber can actually run.
        // Two separate awaits required — ?? right-hand side is @autoclosure (not async).
        let preferredLocale = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
        let fallbackLocale  = await DictationTranscriber.supportedLocale(equivalentTo: Locale.current)
        guard let locale = preferredLocale ?? fallbackLocale else {
            throw AudioCaptureError.deviceLost
        }
#if DEBUG
        print("[DEBUG] DictationEvalEngine using locale: \(locale.identifier)")
#endif

        // Arm 2, production-parity option set (asr_ab_plan.md §3.2.2):
        // - contentHints empty — no farField/atypicalSpeech/customizedLanguage
        //   biasing in this arm.
        // - transcriptionOptions: [.punctuation] — the dictation model
        //   punctuates only on request (unlike SpeechTranscriber's default);
        //   scored references are punctuated, so this is requested explicitly
        //   rather than left at production's `[]`. This is the one place arm
        //   2 differs from a literal copy of production's option values —
        //   everything else below mirrors TranscriptionEngine exactly.
        // - reportingOptions/attributeOptions match production's set exactly
        //   so both arms feed the same rescoring-gate-shaped signal
        //   (confidence distribution comparison is a decision-gate input).
        // - No .emoji / .etiquetteReplacements: silent transforms would
        //   contaminate scoring. Preset inits deliberately avoided (they
        //   bundle undocumented option combinations).
        let transcriber = DictationTranscriber(
            locale: locale,
            contentHints: [],
            transcriptionOptions: [.punctuation],
            reportingOptions: [.volatileResults, .alternativeTranscriptions],
            attributeOptions: [.transcriptionConfidence]
        )

        // Ensure assets are installed; download if needed.
        if let request = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
#if DEBUG
            print("[DEBUG] DictationEvalEngine: downloading speech assets…")
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
        print("[DEBUG] DictationEvalEngine: audio format = \(format)")
#endif

        // Give the audio source the new session continuation and the required format.
        let (analyzerStream, analyzerContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        audioSource.beginSession(continuation: analyzerContinuation, format: format)

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        // Prewarm so the first result isn't delayed by lazy asset loading.
        try? await analyzer.prepareToAnalyze(in: format)

        // Arm-3 smoke rider (asr_ab_plan.md §3.2.3): only set when the caller
        // supplied non-empty contextual strings, so arm 2 (no strings) is
        // byte-for-byte the same code path as a hypothetical arm without this
        // hook. Must happen after the analyzer exists and before
        // analyzeSequence starts consuming audio, per the verified API.
        if let contextualStrings, !contextualStrings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings = [.general: contextualStrings]
            try await analyzer.setContext(context)
#if DEBUG
            print("[DEBUG] DictationEvalEngine: context set with \(contextualStrings.count) contextual string(s)")
#endif
        }

        self.analyzer = analyzer
        self.transcriber = transcriber

        // Feed audio to the analyzer. analyzeSequence returns when the stream finishes.
        analyzerTask = Task {
            do {
                _ = try await analyzer.analyzeSequence(analyzerStream)
#if DEBUG
                print("[DEBUG] DictationEvalEngine: analyzeSequence finished")
#endif
            } catch {
#if DEBUG
                print("[DEBUG] DictationEvalEngine: analyzeSequence error: \(error)")
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
                    // confidence attribute (mirrors the C0 spike finding for
                    // SpeechTranscriber; DictationTranscriber.Result shares the
                    // same SpeechModuleResult-derived shape).
                    let alternatives = result.isFinal
                        ? result.alternatives.map { String($0.characters) }
                        : []
                    let confidence = result.isFinal
                        ? TranscriptionEngine.minimumConfidence(in: result.text)
                        : nil
#if DEBUG
                    print("[DEBUG] DictationEvalEngine: result isFinal=\(result.isFinal) text='\(text)' confidence=\(confidence.map { String(format: "%.2f", $0) } ?? "nil")")
                    if result.isFinal && alternatives.count > 1 {
                        // Manual A/B aid, mirrors production's 10.6 candidate dump.
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
                print("[DEBUG] DictationEvalEngine: results stream ended")
#endif
            } catch {
#if DEBUG
                print("[DEBUG] DictationEvalEngine: results error: \(error)")
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
        // The eval runner's consumer runs during this await and processes the
        // yielded updates into the arm's accumulated transcript.
        if let task = resultTask { await task.value }
        resultTask = nil
        transcriber = nil

        // Signal end of this session's updates stream so the runner's
        // consumer exits naturally after draining any remaining buffered results.
        savedContinuation?.finish()
    }

    // MARK: - Private

    private var updateStream: AsyncStream<TranscriptUpdate>
    private var updateContinuation: AsyncStream<TranscriptUpdate>.Continuation?

    // Held unowned, mirroring production exactly: in the eval harness the
    // A/B runner owns both this engine and the audio source (`FileAudioCapture`)
    // for the run's lifetime, the same way the app delegate owns both in
    // production. The runner must keep the audio source alive for at least
    // as long as this engine's session is active.
    private unowned let audioSource: any AnalyzerAudioSource

    /// Arm-3 smoke-rider payload (asr_ab_plan.md §3.2.3); nil/empty for arms 1–2.
    private let contextualStrings: [String]?

    private var analyzer: SpeechAnalyzer?
    private var transcriber: DictationTranscriber?
    private var analyzerTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?

    init(audioSource: any AnalyzerAudioSource, contextualStrings: [String]? = nil) {
        self.audioSource = audioSource
        self.contextualStrings = contextualStrings
        // Placeholder stream; replaced by a fresh one on each start() call.
        (updateStream, _) = AsyncStream.makeStream(of: TranscriptUpdate.self)
        updateContinuation = nil
    }
}
