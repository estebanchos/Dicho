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

    // MARK: - Internal pipeline state

    private var accumulatedTranscript = ""
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
        isRawMode: Bool = false
    ) {
        self.hotkeyMonitor = hotkeyMonitor
        self.audioCapture = audioCapture
        self.transcriptionEngine = transcriptionEngine
        self.cleanupService = cleanupService
        self.textInserter = textInserter
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
            accumulatedTranscript = accumulatedTranscript.isEmpty
                ? update.text
                : accumulatedTranscript + " " + update.text
            volatileText = ""
        } else if state == .recording {
            volatileText = update.text
        }
    }

    /// Called when `audioCapture.errors` emits — also callable directly from tests.
    func handleAudioCaptureError(_ error: AudioCaptureError) async {
        guard state == .recording else { return }
        let partial = accumulatedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        cancelRecording()
        if !partial.isEmpty {
            // Best-effort: insert partial transcript; on failure it stays in pasteboard.
            try? await textInserter.insert(partial)
        }
        fireNotice(.audioCaptureFailed)
    }

    // MARK: - Private pipeline

    private func startRecording() async {
        do {
            // TranscriptionEngine.start() must run first: it calls audioCapture.beginSession()
            // to register the AnalyzerInput continuation. startCapture() then captures that
            // non-nil continuation in its tap closure. Reversing the order starves the analyzer.
            try await transcriptionEngine.start()
            try audioCapture.startCapture()
        } catch {
            fireNotice(.audioCaptureFailed)
            return
        }

        accumulatedTranscript = ""
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
        // Keep transcriptTask alive during stop(): the engine finalizes volatile results
        // and finishes the updates stream inside stop(). transcriptTask then drains the
        // final results (calling handleTranscriptUpdate) and exits naturally.
        await transcriptionEngine.stop()
        if let task = transcriptTask { await task.value }
        transcriptTask = nil

        // Guard against a cancel event arriving during the above awaits.
        guard state == .transcribing else { return }

        let transcript = accumulatedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        accumulatedTranscript = ""

        guard !transcript.isEmpty else {
            state = .idle
            fireNotice(.nothingHeard)
            return
        }

        await processTranscript(transcript)
    }

    private func cancelRecording() {
        state = .idle
        accumulatedTranscript = ""
        volatileText = ""
        audioCapture.stopCapture()
        transcriptTask?.cancel()
        transcriptTask = nil
        audioCaptureErrorTask?.cancel()
        audioCaptureErrorTask = nil
        // Fire-and-forget; tear down the engine without blocking the cancel path.
        Task { [transcriptionEngine] in await transcriptionEngine.stop() }
    }

    private func processTranscript(_ transcript: String) async {
        guard !isRawMode else {
            await insertText(transcript)
            return
        }

        state = .cleaning(transcript: transcript)

        let textToInsert: String
        do {
            textToInsert = try await withCleanupTimeout {
                try await self.cleanupService.clean(transcript)
            }
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

    /// Races the cleanup operation against `Constants.cleanupChunkTimeout`.
    /// Throws `CleanupError.timeout` if the timeout wins.
    private func withCleanupTimeout<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(Constants.cleanupChunkTimeout))
                throw CleanupError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
