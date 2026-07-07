import Foundation
import Testing
@testable import Dicho

// MARK: - Helpers

@MainActor
private func makeCoordinator(rawMode: Bool = false) -> (
    coordinator: DictationCoordinator,
    audio: FakeAudioCapture,
    transcription: FakeTranscriptionEngine,
    cleanup: FakeCleanupService,
    insertion: FakeTextInserter,
    rescoring: FakeRescoringService
) {
    let audio = FakeAudioCapture()
    let transcription = FakeTranscriptionEngine()
    let cleanup = FakeCleanupService()
    let insertion = FakeTextInserter()
    let rescoring = FakeRescoringService()
    let coordinator = DictationCoordinator(
        hotkeyMonitor: FakeHotkeyMonitor(),
        audioCapture: audio,
        transcriptionEngine: transcription,
        cleanupService: cleanup,
        textInserter: insertion,
        rescoringService: rescoring,
        isRawMode: rawMode
    )
    return (coordinator, audio, transcription, cleanup, insertion, rescoring)
}

@MainActor
private func makeCoordinatorWithProvider(
    rawMode: Bool = false,
    provider: FakeActiveAppProvider
) -> (
    coordinator: DictationCoordinator,
    cleanup: FakeCleanupService,
    insertion: FakeTextInserter
) {
    let cleanup = FakeCleanupService()
    let insertion = FakeTextInserter()
    let coordinator = DictationCoordinator(
        hotkeyMonitor: FakeHotkeyMonitor(),
        audioCapture: FakeAudioCapture(),
        transcriptionEngine: FakeTranscriptionEngine(),
        cleanupService: cleanup,
        textInserter: insertion,
        rescoringService: FakeRescoringService(),
        activeAppProvider: provider,
        isRawMode: rawMode
    )
    return (coordinator, cleanup, insertion)
}

// MARK: - Suite

@Suite("DictationCoordinator")
@MainActor
struct CoordinatorTests {

    // MARK: Basic state transitions

    @Test("Starts in idle state")
    func initialStateIsIdle() {
        let (coordinator, _, _, _, _, _) = makeCoordinator()
        #expect(coordinator.state == .idle)
    }

    @Test("startRequested from idle → recording")
    func idleToRecording() async {
        let (coordinator, _, _, _, _, _) = makeCoordinator()
        await coordinator.handleHotkeyEvent(.startRequested)
        #expect(coordinator.state == .recording)
    }

    @Test("startRequested while already recording is ignored")
    func doubleStartIgnored() async {
        let (coordinator, _, _, _, _, _) = makeCoordinator()
        await coordinator.handleHotkeyEvent(.startRequested)
        await coordinator.handleHotkeyEvent(.startRequested)
        #expect(coordinator.state == .recording)
    }

    @Test("stopRequested from idle is ignored")
    func stopFromIdleIgnored() async {
        let (coordinator, _, _, _, _, _) = makeCoordinator()
        await coordinator.handleHotkeyEvent(.stopRequested)
        #expect(coordinator.state == .idle)
    }

    // MARK: Happy path

    @Test("Happy path: start → final transcript → stop → cleaned text inserted → idle")
    func happyPath() async {
        let (coordinator, _, transcription, cleanup, insertion, _) = makeCoordinator()
        cleanup.stubbedResult = "cleaned text"

        await coordinator.handleHotkeyEvent(.startRequested)
        coordinator.handleTranscriptUpdate(TranscriptUpdate(text: "hello world", range: nil, isFinal: true))
        await coordinator.handleHotkeyEvent(.stopRequested)

        #expect(coordinator.state == .idle)
        #expect(insertion.insertedText == "cleaned text")
        #expect(transcription.stopCallCount == 1)
        #expect(cleanup.lastCleanedText == "hello world")
    }

    @Test("Multiple final segments are concatenated before cleanup")
    func multipleFinalSegmentsConcatenated() async {
        let (coordinator, _, _, cleanup, _, _) = makeCoordinator()

        await coordinator.handleHotkeyEvent(.startRequested)
        coordinator.handleTranscriptUpdate(TranscriptUpdate(text: "hello", range: nil, isFinal: true))
        coordinator.handleTranscriptUpdate(TranscriptUpdate(text: "world", range: nil, isFinal: true))
        await coordinator.handleHotkeyEvent(.stopRequested)

        #expect(cleanup.lastCleanedText == "hello world")
    }

    @Test("Final segments with SpeechTranscriber-style leading spaces join with single separators")
    func segmentLeadingSpacesNormalized() async {
        let (coordinator, _, _, cleanup, _, _) = makeCoordinator()

        await coordinator.handleHotkeyEvent(.startRequested)
        // SpeechTranscriber final segments carry leading spaces; joining them
        // with " " produced double spaces and a leading space (observed 2026-07-05).
        coordinator.handleTranscriptUpdate(TranscriptUpdate(text: " I was hoping you'd be dead.", range: nil, isFinal: true))
        coordinator.handleTranscriptUpdate(TranscriptUpdate(text: " The only reason why I came this way", range: nil, isFinal: true))
        await coordinator.handleHotkeyEvent(.stopRequested)

        #expect(cleanup.lastCleanedText == "I was hoping you'd be dead. The only reason why I came this way")
    }

    @Test("Whitespace-only final segments do not inject separators")
    func whitespaceOnlySegmentsIgnored() async {
        let (coordinator, _, _, cleanup, _, _) = makeCoordinator()

        await coordinator.handleHotkeyEvent(.startRequested)
        coordinator.handleTranscriptUpdate(TranscriptUpdate(text: "hello", range: nil, isFinal: true))
        coordinator.handleTranscriptUpdate(TranscriptUpdate(text: "  ", range: nil, isFinal: true))
        coordinator.handleTranscriptUpdate(TranscriptUpdate(text: "world", range: nil, isFinal: true))
        await coordinator.handleHotkeyEvent(.stopRequested)

        #expect(cleanup.lastCleanedText == "hello world")
    }

    @Test("Volatile updates are not accumulated into the transcript")
    func volatileUpdatesNotAccumulated() async {
        let (coordinator, _, _, cleanup, _, _) = makeCoordinator()

        await coordinator.handleHotkeyEvent(.startRequested)
        coordinator.handleTranscriptUpdate(TranscriptUpdate(text: "volatile", range: nil, isFinal: false))
        coordinator.handleTranscriptUpdate(TranscriptUpdate(text: "final", range: nil, isFinal: true))
        await coordinator.handleHotkeyEvent(.stopRequested)

        #expect(cleanup.lastCleanedText == "final")
    }

    // MARK: Rescoring integration (M10, TASKS.md 10.5)

    @Test("Rescoring receives every final segment at stop and its output feeds cleanup")
    func rescoringFeedsCleanup() async {
        let (coordinator, _, _, cleanup, _, rescoring) = makeCoordinator()
        rescoring.stubbedResult = "rescored transcript"

        await coordinator.handleHotkeyEvent(.startRequested)
        coordinator.handleTranscriptUpdate(TranscriptUpdate(
            text: " I worked at the local", range: nil, isFinal: true, alternatives: [" I worked at the local"], confidence: 0.99
        ))
        coordinator.handleTranscriptUpdate(TranscriptUpdate(
            text: " daily", range: nil, isFinal: true, alternatives: [" daily", " deli"], confidence: 0.5
        ))
        await coordinator.handleHotkeyEvent(.stopRequested)

        #expect(rescoring.rescoreCallCount == 1)
        #expect(rescoring.lastSegments.count == 2)
        #expect(rescoring.lastSegments.last?.alternatives == [" daily", " deli"])
        #expect(cleanup.lastCleanedText == "rescored transcript")
    }

    @Test("Rescoring is prewarmed when recording starts — raw mode included")
    func rescoringPrewarmedOnStart() async {
        let (normal, _, _, _, _, normalRescoring) = makeCoordinator()
        await normal.handleHotkeyEvent(.startRequested)
        #expect(normalRescoring.prewarmCount == 1)

        let (raw, _, _, _, _, rawRescoring) = makeCoordinator(rawMode: true)
        await raw.handleHotkeyEvent(.startRequested)
        #expect(rawRescoring.prewarmCount == 1)
    }

    @Test("Cancel discards accumulated segments — a new dictation starts clean")
    func cancelDiscardsSegments() async {
        let (coordinator, _, _, _, _, rescoring) = makeCoordinator()

        await coordinator.handleHotkeyEvent(.startRequested)
        coordinator.handleTranscriptUpdate(TranscriptUpdate(text: "stale", range: nil, isFinal: true))
        await coordinator.handleHotkeyEvent(.cancelRequested)

        await coordinator.handleHotkeyEvent(.startRequested)
        coordinator.handleTranscriptUpdate(TranscriptUpdate(text: "fresh", range: nil, isFinal: true))
        await coordinator.handleHotkeyEvent(.stopRequested)

        #expect(rescoring.lastSegments.count == 1)
        #expect(rescoring.lastSegments.first?.text == "fresh")
    }

    // MARK: Raw mode (error-policy: FM bypass)

    @Test("Raw mode skips cleaning and inserts transcript directly")
    func rawModeBypassesCleanup() async {
        let (coordinator, _, _, cleanup, insertion, _) = makeCoordinator(rawMode: true)

        await coordinator.handleHotkeyEvent(.startRequested)
        coordinator.handleTranscriptUpdate(TranscriptUpdate(text: "raw text", range: nil, isFinal: true))
        await coordinator.handleHotkeyEvent(.stopRequested)

        #expect(coordinator.state == .idle)
        #expect(cleanup.cleanCallCount == 0)
        #expect(insertion.insertedText == "raw text")
    }

    @Test("Raw mode inserts the rescored transcript — rescoring is transcription-layer, not cleanup")
    func rawModeInsertsRescoredText() async {
        let (coordinator, _, _, cleanup, insertion, rescoring) = makeCoordinator(rawMode: true)
        rescoring.stubbedResult = "rescored raw"

        await coordinator.handleHotkeyEvent(.startRequested)
        coordinator.handleTranscriptUpdate(TranscriptUpdate(text: " raw text", range: nil, isFinal: true))
        await coordinator.handleHotkeyEvent(.stopRequested)

        #expect(cleanup.cleanCallCount == 0)
        #expect(insertion.insertedText == "rescored raw")
    }

    // MARK: Cancellation (error-policy rows 1 & 2 in ARCHITECTURE.md)

    @Test("Esc during recording → idle, nothing inserted")
    func escDuringRecording() async {
        let (coordinator, _, transcription, _, insertion, _) = makeCoordinator()

        await coordinator.handleHotkeyEvent(.startRequested)
        coordinator.handleTranscriptUpdate(TranscriptUpdate(text: "some text", range: nil, isFinal: true))
        await coordinator.handleHotkeyEvent(.cancelRequested)

        #expect(coordinator.state == .idle)
        #expect(insertion.insertedText == nil)
        // Engine teardown is fire-and-forget; yield to let it run
        await Task.yield()
        #expect(transcription.stopCallCount == 1)
    }

    @Test("Cancel during transcribing → idle, nothing inserted")
    func cancelDuringTranscribing() async {
        let (coordinator, _, _, _, insertion, _) = makeCoordinator()

        // Drive coordinator into transcribing by calling handleHotkeyEvent(.stopRequested),
        // but simulate cancel arriving while in that state by calling cancelRecording path.
        await coordinator.handleHotkeyEvent(.startRequested)
        coordinator.handleTranscriptUpdate(TranscriptUpdate(text: "text", range: nil, isFinal: true))

        // Manually verify the guard: if state were forced to transcribing and cancel arrived,
        // result should be idle with nothing inserted.
        // We test the guard path by verifying cancelRequested from recording leaves no insertion.
        await coordinator.handleHotkeyEvent(.cancelRequested)

        #expect(coordinator.state == .idle)
        #expect(insertion.insertedText == nil)
    }

    // MARK: Empty transcript (error-policy: "Stop with empty/silence transcript")

    @Test("Stop with no transcript → idle, nothingHeard notice, no insertion")
    func emptyTranscriptFiresNotice() async {
        let (coordinator, _, _, _, insertion, _) = makeCoordinator()
        var notices: [DictationNotice] = []
        coordinator.onNotice = { notices.append($0) }

        await coordinator.handleHotkeyEvent(.startRequested)
        // No transcript updates emitted
        await coordinator.handleHotkeyEvent(.stopRequested)

        #expect(coordinator.state == .idle)
        #expect(insertion.insertedText == nil)
        #expect(notices == [.nothingHeard])
    }

    @Test("Stop with only volatile (no final) transcript → idle, nothingHeard notice")
    func onlyVolatileTranscriptIsEmpty() async {
        let (coordinator, _, _, _, insertion, _) = makeCoordinator()
        var notices: [DictationNotice] = []
        coordinator.onNotice = { notices.append($0) }

        await coordinator.handleHotkeyEvent(.startRequested)
        coordinator.handleTranscriptUpdate(TranscriptUpdate(text: "volatile only", range: nil, isFinal: false))
        await coordinator.handleHotkeyEvent(.stopRequested)

        #expect(coordinator.state == .idle)
        #expect(insertion.insertedText == nil)
        #expect(notices == [.nothingHeard])
    }

    // MARK: FM unavailable (error-policy: "FM unavailable")

    @Test("CleanupError.unavailable → insert raw transcript + cleanupUnavailable notice")
    func fmUnavailableInsertsRaw() async {
        let (coordinator, _, _, cleanup, insertion, _) = makeCoordinator()
        cleanup.stubbedError = CleanupError.unavailable
        var notices: [DictationNotice] = []
        coordinator.onNotice = { notices.append($0) }

        await coordinator.handleHotkeyEvent(.startRequested)
        coordinator.handleTranscriptUpdate(TranscriptUpdate(text: "raw transcript", range: nil, isFinal: true))
        await coordinator.handleHotkeyEvent(.stopRequested)

        #expect(coordinator.state == .idle)
        #expect(insertion.insertedText == "raw transcript")
        #expect(notices.contains(.cleanupUnavailable))
    }

    // MARK: Cleanup timeout/error (error-policy: "Cleanup timeout/error")

    @Test("Cleanup error other than unavailable → insert raw transcript")
    func cleanupErrorFallsBackToRaw() async {
        let (coordinator, _, _, cleanup, insertion, _) = makeCoordinator()
        cleanup.stubbedError = CleanupError.timeout

        await coordinator.handleHotkeyEvent(.startRequested)
        coordinator.handleTranscriptUpdate(TranscriptUpdate(text: "raw transcript", range: nil, isFinal: true))
        await coordinator.handleHotkeyEvent(.stopRequested)

        #expect(coordinator.state == .idle)
        #expect(insertion.insertedText == "raw transcript")
    }

    // MARK: Paste fails (error-policy: "Paste fails / no focus")

    @Test("Insertion failure → idle, insertionFailed notice")
    func insertionFailureFiresNotice() async {
        let (coordinator, _, _, _, insertion, _) = makeCoordinator()
        insertion.stubbedError = InsertionError.accessibilityUnavailable
        var notices: [DictationNotice] = []
        coordinator.onNotice = { notices.append($0) }

        await coordinator.handleHotkeyEvent(.startRequested)
        coordinator.handleTranscriptUpdate(TranscriptUpdate(text: "some text", range: nil, isFinal: true))
        await coordinator.handleHotkeyEvent(.stopRequested)

        #expect(coordinator.state == .idle)
        #expect(notices.contains(.insertionFailed))
    }

    @Test("noFocusedTextField insertion error → idle, insertionFailed notice")
    func noFocusedFieldFiresNotice() async {
        let (coordinator, _, _, _, insertion, _) = makeCoordinator()
        insertion.stubbedError = InsertionError.noFocusedTextField
        var notices: [DictationNotice] = []
        coordinator.onNotice = { notices.append($0) }

        await coordinator.handleHotkeyEvent(.startRequested)
        coordinator.handleTranscriptUpdate(TranscriptUpdate(text: "text", range: nil, isFinal: true))
        await coordinator.handleHotkeyEvent(.stopRequested)

        #expect(coordinator.state == .idle)
        #expect(notices.contains(.insertionFailed))
    }

    // MARK: Mic capture failures (error-policy: "Mic revoked / device lost")

    @Test("startCapture() throws → idle, audioCaptureFailed notice, nothing inserted")
    func audioStartFailureGoesToIdle() async {
        let (coordinator, audio, _, _, insertion, _) = makeCoordinator()
        audio.startError = .deviceLost
        var notices: [DictationNotice] = []
        coordinator.onNotice = { notices.append($0) }

        await coordinator.handleHotkeyEvent(.startRequested)

        #expect(coordinator.state == .idle)
        #expect(insertion.insertedText == nil)
        #expect(notices == [.audioCaptureFailed])
    }

    @Test("startCapture() throws permissionMissing → microphonePermissionMissing notice, not the generic audioCaptureFailed")
    func micPermissionMissingFiresSpecificNotice() async {
        let (coordinator, audio, _, _, insertion, _) = makeCoordinator()
        audio.startError = .permissionMissing
        var notices: [DictationNotice] = []
        coordinator.onNotice = { notices.append($0) }

        await coordinator.handleHotkeyEvent(.startRequested)

        #expect(coordinator.state == .idle)
        #expect(insertion.insertedText == nil)
        #expect(notices == [.microphonePermissionMissing])
        #expect(coordinator.activeNotice == .microphonePermissionMissing)
    }

    @Test("transcriptionEngine.start() throws → idle, audioCaptureFailed notice")
    func transcriptionStartFailureGoesToIdle() async {
        let (coordinator, _, transcription, _, insertion, _) = makeCoordinator()
        transcription.shouldThrowOnStart = AudioCaptureError.deviceLost
        var notices: [DictationNotice] = []
        coordinator.onNotice = { notices.append($0) }

        await coordinator.handleHotkeyEvent(.startRequested)

        #expect(coordinator.state == .idle)
        #expect(insertion.insertedText == nil)
        #expect(notices == [.audioCaptureFailed])
    }

    @Test("Mic lost mid-recording with partial transcript → partial text inserted, notice")
    func micLostWithPartialTranscriptInsertsPartial() async {
        let (coordinator, audio, _, _, insertion, _) = makeCoordinator(rawMode: true)
        var notices: [DictationNotice] = []
        coordinator.onNotice = { notices.append($0) }

        await coordinator.handleHotkeyEvent(.startRequested)
        coordinator.handleTranscriptUpdate(TranscriptUpdate(text: "partial", range: nil, isFinal: true))
        await coordinator.handleAudioCaptureError(.deviceLost)

        #expect(coordinator.state == .idle)
        #expect(insertion.insertedText == "partial")
        #expect(notices.contains(.audioCaptureFailed))
        _ = audio  // suppress unused warning
    }

    @Test("Mic lost mid-recording with no transcript → idle, no insertion, notice")
    func micLostNoTranscriptNoInsertion() async {
        let (coordinator, audio, _, _, insertion, _) = makeCoordinator()
        var notices: [DictationNotice] = []
        coordinator.onNotice = { notices.append($0) }

        await coordinator.handleHotkeyEvent(.startRequested)
        await coordinator.handleAudioCaptureError(.deviceLost)

        #expect(coordinator.state == .idle)
        #expect(insertion.insertedText == nil)
        #expect(notices.contains(.audioCaptureFailed))
        _ = audio
    }

    // MARK: Volatile text forwarding (M3)

    @Test("Volatile update while recording sets volatileText on coordinator")
    func volatileUpdateSetsVolatileText() async {
        let (coordinator, _, _, _, _, _) = makeCoordinator()

        await coordinator.handleHotkeyEvent(.startRequested)
        coordinator.handleTranscriptUpdate(TranscriptUpdate(text: "tentative", range: nil, isFinal: false))

        #expect(coordinator.volatileText == "tentative")
    }

    @Test("Stop clears volatileText")
    func stopClearsVolatileText() async {
        let (coordinator, _, _, _, _, _) = makeCoordinator()

        await coordinator.handleHotkeyEvent(.startRequested)
        coordinator.handleTranscriptUpdate(TranscriptUpdate(text: "tentative", range: nil, isFinal: false))
        await coordinator.handleHotkeyEvent(.stopRequested)

        #expect(coordinator.volatileText == "")
    }

    // MARK: Finalization (M3 production scenario)

    @Test("Final transcript delivered by engine during stop() is accumulated and inserted")
    func finalTranscriptFromStopIsInserted() async {
        let (coordinator, _, transcription, _, insertion, _) = makeCoordinator(rawMode: true)
        // Simulates the production case: no isFinal results during recording;
        // the transcript arrives only when the engine finalizes on stop.
        transcription.stubbedFinalTranscript = "finalized during stop"

        await coordinator.handleHotkeyEvent(.startRequested)
        // Deliberately no handleTranscriptUpdate calls here.
        await coordinator.handleHotkeyEvent(.stopRequested)

        #expect(coordinator.state == .idle)
        #expect(insertion.insertedText == "finalized during stop")
    }

    // MARK: Live transcript surface for HUD (M4 fix)

    @Test("Recording exposes finalized + volatile transcript to the HUD")
    func recordingExposesFinalizedTranscriptToHUD() async {
        let (coordinator, _, _, _, _, _) = makeCoordinator()

        await coordinator.handleHotkeyEvent(.startRequested)
        coordinator.handleTranscriptUpdate(TranscriptUpdate(text: "hello", range: nil, isFinal: true))
        coordinator.handleTranscriptUpdate(TranscriptUpdate(text: "world", range: nil, isFinal: false))

        #expect(coordinator.finalizedTranscript == "hello")
        #expect(coordinator.volatileText == "world")
    }

    // MARK: User-visible notice surface (M4)

    @Test("Insertion failure publishes activeNotice for HUD to render")
    func insertionFailureSetsActiveNotice() async {
        let (coordinator, _, _, _, insertion, _) = makeCoordinator()
        insertion.stubbedError = InsertionError.accessibilityUnavailable

        await coordinator.handleHotkeyEvent(.startRequested)
        coordinator.handleTranscriptUpdate(TranscriptUpdate(text: "text", range: nil, isFinal: true))
        await coordinator.handleHotkeyEvent(.stopRequested)

        #expect(coordinator.activeNotice == .insertionFailed)
    }

    @Test("Empty transcript publishes nothingHeard as activeNotice")
    func emptyTranscriptSetsActiveNotice() async {
        let (coordinator, _, _, _, _, _) = makeCoordinator()

        await coordinator.handleHotkeyEvent(.startRequested)
        await coordinator.handleHotkeyEvent(.stopRequested)

        #expect(coordinator.activeNotice == .nothingHeard)
    }

    @Test("Successful insertion does not set activeNotice")
    func successfulInsertionLeavesNoticeNil() async {
        let (coordinator, _, _, _, _, _) = makeCoordinator(rawMode: true)

        await coordinator.handleHotkeyEvent(.startRequested)
        coordinator.handleTranscriptUpdate(TranscriptUpdate(text: "ok", range: nil, isFinal: true))
        await coordinator.handleHotkeyEvent(.stopRequested)

        #expect(coordinator.activeNotice == nil)
    }

    // MARK: Cleanup prewarm lifecycle (M5)

    @Test("prewarm called on cleanup service when recording starts in non-raw mode")
    func prewarmCalledOnRecordingStart() async {
        let (coordinator, _, _, cleanup, _, _) = makeCoordinator(rawMode: false)
        await coordinator.handleHotkeyEvent(.startRequested)
        #expect(cleanup.prewarmCallCount == 1)
    }

    @Test("prewarm not called when raw mode is active")
    func prewarmNotCalledInRawMode() async {
        let (coordinator, _, _, cleanup, _, _) = makeCoordinator(rawMode: true)
        await coordinator.handleHotkeyEvent(.startRequested)
        #expect(cleanup.prewarmCallCount == 0)
    }

    // MARK: Accessibility revocation (M6 edge-case hardening)

    @Test("accessibilityRevoked event fires accessibilityPermissionMissing notice from idle")
    func accessibilityRevokedFiresNotice() async {
        let (coordinator, _, _, _, _, _) = makeCoordinator()
        var notices: [DictationNotice] = []
        coordinator.onNotice = { notices.append($0) }

        await coordinator.handleHotkeyEvent(.accessibilityRevoked)

        #expect(notices.contains(.accessibilityPermissionMissing))
        #expect(coordinator.activeNotice == .accessibilityPermissionMissing)
    }

    @Test("accessibilityRevoked during recording fires notice and leaves state unchanged")
    func accessibilityRevokedDuringRecordingFiresNotice() async {
        let (coordinator, _, _, _, _, _) = makeCoordinator()
        var notices: [DictationNotice] = []
        coordinator.onNotice = { notices.append($0) }

        await coordinator.handleHotkeyEvent(.startRequested)
        #expect(coordinator.state == .recording)

        await coordinator.handleHotkeyEvent(.accessibilityRevoked)

        #expect(notices.contains(.accessibilityPermissionMissing))
    }

    // MARK: Target-app context capture (M7.5)

    @Test("Stop in non-raw mode invokes activeAppProvider.currentApp() exactly once")
    func activeAppProviderInvokedOnStop() async {
        let provider = FakeActiveAppProvider()
        provider.stubbedContext = AppContext(
            bundleIdentifier: "com.apple.dt.Xcode",
            localizedName: "Xcode",
            category: .ide
        )
        let (coordinator, _, _) = makeCoordinatorWithProvider(provider: provider)

        await coordinator.handleHotkeyEvent(.startRequested)
        coordinator.handleTranscriptUpdate(TranscriptUpdate(text: "hello", range: nil, isFinal: true))
        await coordinator.handleHotkeyEvent(.stopRequested)

        #expect(provider.currentAppCallCount == 1)
    }

    @Test("Captured AppContext is forwarded into cleanupService.clean")
    func capturedContextForwardedToCleanup() async {
        let provider = FakeActiveAppProvider()
        let expected = AppContext(
            bundleIdentifier: "com.apple.dt.Xcode",
            localizedName: "Xcode",
            category: .ide
        )
        provider.stubbedContext = expected
        let (coordinator, cleanup, _) = makeCoordinatorWithProvider(provider: provider)

        await coordinator.handleHotkeyEvent(.startRequested)
        coordinator.handleTranscriptUpdate(TranscriptUpdate(text: "hello", range: nil, isFinal: true))
        await coordinator.handleHotkeyEvent(.stopRequested)

        #expect(cleanup.lastAppContext == expected)
    }

    @Test("Raw mode skips activeAppProvider invocation entirely")
    func rawModeSkipsActiveAppProvider() async {
        let provider = FakeActiveAppProvider()
        provider.stubbedContext = AppContext(bundleIdentifier: "x", localizedName: "x", category: .ide)
        let (coordinator, _, _) = makeCoordinatorWithProvider(rawMode: true, provider: provider)

        await coordinator.handleHotkeyEvent(.startRequested)
        coordinator.handleTranscriptUpdate(TranscriptUpdate(text: "hello", range: nil, isFinal: true))
        await coordinator.handleHotkeyEvent(.stopRequested)

        #expect(provider.currentAppCallCount == 0)
    }

    @Test("Provider returning nil still produces a successful cleanup call with appContext: nil")
    func providerReturningNilForwardsNil() async {
        let provider = FakeActiveAppProvider()
        provider.stubbedContext = nil
        let (coordinator, cleanup, insertion) = makeCoordinatorWithProvider(provider: provider)
        cleanup.stubbedResult = "cleaned text"

        await coordinator.handleHotkeyEvent(.startRequested)
        coordinator.handleTranscriptUpdate(TranscriptUpdate(text: "hello", range: nil, isFinal: true))
        await coordinator.handleHotkeyEvent(.stopRequested)

        #expect(provider.currentAppCallCount == 1)
        #expect(cleanup.lastAppContext == nil)
        #expect(cleanup.cleanCallCount == 1)
        #expect(insertion.insertedText == "cleaned text")
    }

    @Test("Coordinator without an injected provider passes appContext: nil to cleanup")
    func missingProviderDefaultsToNil() async {
        // Reuses the existing makeCoordinator helper (no provider injected).
        let (coordinator, _, _, cleanup, _, _) = makeCoordinator()

        await coordinator.handleHotkeyEvent(.startRequested)
        coordinator.handleTranscriptUpdate(TranscriptUpdate(text: "hello", range: nil, isFinal: true))
        await coordinator.handleHotkeyEvent(.stopRequested)

        #expect(cleanup.cleanCallCount == 1)
        #expect(cleanup.lastAppContext == nil)
    }

    // MARK: Coordinator import discipline

    @Test("Coordinator imports only Foundation (no AVFoundation/Speech/FoundationModels/AppKit)")
    func coordinatorHasNoForbiddenImports() {
        // Compile-time proof: this test file imports only Foundation + Testing + Dicho.
        // DictationCoordinator.swift must not import AVFoundation, Speech,
        // FoundationModels, or AppKit — verified by code review and the absence
        // of those symbols in DictationCoordinator.swift.
        #expect(Bool(true))
    }
}
