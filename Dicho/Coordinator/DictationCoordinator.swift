import Foundation
import Observation

/// The core pipeline orchestrator. Owns all state transitions, cancellation,
/// timeout policy, and the raw-mode bypass decision.
///
/// Isolated to `@MainActor` so SwiftUI views can observe `state` directly.
/// All injected collaborators are accessed only from the main actor.
@Observable
@MainActor
final class DictationCoordinator {

    // MARK: - Observable state

    private(set) var state: DictationState = .idle
    /// Finalized transcript so far during the current recording session.
    /// Rendered at full opacity in the HUD; concatenated with `volatileText`
    /// (dimmed) to form the live preview. Cleared on start, stop, and cancel.
    private(set) var finalizedTranscript: String = ""

    /// Finalized segments with their n-best alternatives and confidence,
    /// accumulated for the stop-time rescoring pass (M10). `finalizedTranscript`
    /// remains the plain-string mirror for the HUD and error paths.
    private var finalizedSegments: [TranscriptUpdate] = []
    /// Current volatile (provisional) transcript text; empty when not recording.
    private(set) var volatileText: String = ""
    /// Last fired notice, surfaced to the HUD for transient display.
    /// Auto-clears after `Constants.noticeDisplayDuration`.
    private(set) var activeNotice: DictationNotice?

    /// When true the cleaning state is skipped; raw transcript is inserted.
    var isRawMode: Bool

    // MARK: - Notice callback (kept for test introspection alongside activeNotice)

    var onNotice: (@MainActor (DictationNotice) -> Void)?

    // MARK: - Dependencies

    private let hotkeyMonitor: any HotkeyMonitoring
    private let audioCapture: any AudioCapturing
    private let transcriptionEngine: any TranscriptionEngineProtocol
    private let cleanupService: any CleanupServicing
    private let textInserter: any TextInserting
    private let rescoringService: any RescoringServicing
    private let activeAppProvider: (any ActiveAppProviding)?

    // MARK: - Internal pipeline state

    private var hotkeyTask: Task<Void, Never>?
    private var transcriptTask: Task<Void, Never>?
    private var audioCaptureErrorTask: Task<Void, Never>?
    private var noticeClearTask: Task<Void, Never>?

    // MARK: - Init

    init(
        hotkeyMonitor: any HotkeyMonitoring,
        audioCapture: any AudioCapturing,
        transcriptionEngine: any TranscriptionEngineProtocol,
        cleanupService: any CleanupServicing,
        textInserter: any TextInserting,
        rescoringService: any RescoringServicing,
        activeAppProvider: (any ActiveAppProviding)? = nil,
        isRawMode: Bool = false
    ) {
        self.hotkeyMonitor = hotkeyMonitor
        self.audioCapture = audioCapture
        self.transcriptionEngine = transcriptionEngine
        self.cleanupService = cleanupService
        self.textInserter = textInserter
        self.rescoringService = rescoringService
        self.activeAppProvider = activeAppProvider
        self.isRawMode = isRawMode
    }

    // MARK: - Hotkey listening

    func startListening() {
        try? hotkeyMonitor.start()
        hotkeyTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.hotkeyMonitor.events {
                await self.handleHotkeyEvent(event)
            }
        }
    }

    func stopListening() {
        hotkeyMonitor.stop()
        hotkeyTask?.cancel()
        hotkeyTask = nil
    }

    // MARK: - Event handlers (internal visibility allows direct call from tests)

    func handleHotkeyEvent(_ event: HotkeyEvent) async {
        switch (state, event) {
        case (.idle, .startRequested):
            await startRecording()
        case (.recording, .stopRequested):
            await stopRecording()
        case (.recording, .cancelRequested),
             (.transcribing, .cancelRequested):
            cancelRecording()
        case (_, .accessibilityRevoked):
            // Tap was silently disabled and AX trust is gone; surface via notice so
            // the app shell can re-open onboarding without coupling to AppKit here.
            fireNotice(.accessibilityPermissionMissing)
        default:
            break
        }
    }

    /// Accumulates final transcript segments; forwards volatile text to HUD via `volatileText`.
    ///
    /// Final results are also accepted during `.transcribing`: with `progressiveTranscription`
    /// the engine only finalizes volatile results when `stop()` calls
    /// `finalizeAndFinishThroughEndOfInput()`, which runs after the state has already
    /// advanced to `.transcribing`.
    func handleTranscriptUpdate(_ update: TranscriptUpdate) {
        guard state == .recording || state == .transcribing else { return }
        if update.isFinal {
            // Full updates (with alternatives + confidence) accumulate for the
            // stop-time rescoring pass; the string mirror below feeds the HUD
            // and the audio-error partial-insert path.
            finalizedSegments.append(update)
            // SpeechTranscriber final segments arrive with leading spaces; trim
            // each segment before joining or the transcript accumulates double
            // spaces at every segment boundary (raw mode and cleanup alike).
            let segment = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !segment.isEmpty {
                finalizedTranscript = finalizedTranscript.isEmpty
                    ? segment
                    : finalizedTranscript + " " + segment
            }
            volatileText = ""
        } else if state == .recording {
            volatileText = update.text
        }
    }

    /// Called when `audioCapture.errors` emits — also callable directly from tests.
    func handleAudioCaptureError(_ error: AudioCaptureError) async {
        guard state == .recording else { return }
        let partial = finalizedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        cancelRecording()
        if !partial.isEmpty {
            // Best-effort: insert partial transcript; on failure it stays in pasteboard.
            try? await textInserter.insert(partial)
        }
        fireNotice(.audioCaptureFailed)
    }

    // MARK: - Private pipeline

    private func startRecording() async {
        // Prewarm the FM session now so it's ready by the time cleanup is needed.
        if !isRawMode {
            cleanupService.prewarm()
        }
        // Rescoring applies in raw mode too (transcription-layer repair, not
        // cleanup), so its selector prewarms regardless of the mode.
        rescoringService.prewarm()

        do {
            // TranscriptionEngine.start() must run first: it calls audioCapture.beginSession()
            // to register the AnalyzerInput continuation. startCapture() then captures that
            // non-nil continuation in its tap closure. Reversing the order starves the analyzer.
            try await transcriptionEngine.start()
            try audioCapture.startCapture()
        } catch AudioCaptureError.permissionMissing {
            fireNotice(.microphonePermissionMissing)
            return
        } catch {
            fireNotice(.audioCaptureFailed)
            return
        }

        finalizedTranscript = ""
        finalizedSegments = []
        state = .recording

        transcriptTask = Task { [weak self] in
            guard let self else { return }
            for await update in self.transcriptionEngine.updates {
                self.handleTranscriptUpdate(update)
            }
        }

        audioCaptureErrorTask = Task { [weak self] in
            guard let self else { return }
            for await error in self.audioCapture.errors {
                await self.handleAudioCaptureError(error)
            }
        }
    }

    private func stopRecording() async {
        state = .transcribing
        volatileText = ""
        audioCapture.stopCapture()
        audioCaptureErrorTask?.cancel()
        audioCaptureErrorTask = nil

        // Capture frontmost-app context BEFORE any await. NSRunningApplication's
        // time-varying properties are only fresh within the current main-run-loop
        // turn; this is the closest moment to the user's hotkey-press intent.
        // Raw mode bypasses cleanup, so the capture is skipped.
        let appContext: AppContext? = isRawMode ? nil : activeAppProvider?.currentApp()
#if DEBUG
        let categoryDesc = appContext.map { String(describing: $0.category) } ?? "nil"
        print(
            "[DEBUG] AppContext captured at stop: "
            + "bundleID=\(appContext?.bundleIdentifier ?? "nil") "
            + "name=\(appContext?.localizedName ?? "nil") "
            + "category=\(categoryDesc)"
        )
#endif

        // Keep transcriptTask alive during stop(): the engine finalizes volatile results
        // and finishes the updates stream inside stop(). transcriptTask then drains the
        // final results (calling handleTranscriptUpdate) and exits naturally.
        await transcriptionEngine.stop()
        if let task = transcriptTask { await task.value }
        transcriptTask = nil

        // Guard against a cancel event arriving during the above awaits.
        guard state == .transcribing else { return }

        let segments = finalizedSegments
        finalizedSegments = []
        finalizedTranscript = ""

        // Rescoring pass (M10): resolve ambiguous segments to their best
        // n-best candidate before cleanup. Total and non-throwing — worst
        // case it returns the transcriber's top hypotheses reassembled.
        let transcript = await rescoringService.rescore(segments)

        // Guard against a cancel arriving during the rescoring await.
        guard state == .transcribing else { return }

        guard !transcript.isEmpty else {
            state = .idle
            fireNotice(.nothingHeard)
            return
        }

        await processTranscript(transcript, appContext: appContext)
    }

    private func cancelRecording() {
        state = .idle
        finalizedTranscript = ""
        finalizedSegments = []
        volatileText = ""
        audioCapture.stopCapture()
        transcriptTask?.cancel()
        transcriptTask = nil
        audioCaptureErrorTask?.cancel()
        audioCaptureErrorTask = nil
        // Fire-and-forget; tear down the engine without blocking the cancel path.
        Task { [transcriptionEngine] in await transcriptionEngine.stop() }
    }

    private func processTranscript(_ transcript: String, appContext: AppContext?) async {
        guard !isRawMode else {
            await insertText(transcript)
            return
        }

        state = .cleaning(transcript: transcript)

        let textToInsert: String
        do {
            // CleanupService now owns the per-chunk timeout (and session rotation
            // on timeout/overflow), so the coordinator calls clean() directly.
            textToInsert = try await cleanupService.clean(transcript, appContext: appContext)
        } catch CleanupError.unavailable {
            textToInsert = transcript
            fireNotice(.cleanupUnavailable)
        } catch {
            // Timeout or any other cleanup error → fall back to raw transcript.
            textToInsert = transcript
        }

        // Guard against a cancel arriving during the cleanup await.
        guard case .cleaning = state else { return }

        await insertText(textToInsert)
    }

    private func insertText(_ text: String) async {
        state = .inserting(text: text)
        do {
            try await textInserter.insert(text)
        } catch {
            fireNotice(.insertionFailed)
        }
        state = .idle
    }

    /// Publishes a notice on the observable surface, invokes the callback for any
    /// test/log observer, and schedules an auto-clear of `activeNotice` after
    /// `Constants.noticeDisplayDuration`. Replacing a still-displayed notice
    /// cancels the previous clear task so the new notice gets a full display.
    private func fireNotice(_ notice: DictationNotice) {
        activeNotice = notice
        onNotice?(notice)
        noticeClearTask?.cancel()
        noticeClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Constants.noticeDisplayDuration))
            guard !Task.isCancelled else { return }
            self?.activeNotice = nil
        }
    }
}
