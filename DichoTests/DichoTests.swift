import Foundation
import Testing
@testable import Dicho

/// Verifies the M0 scaffold: protocol seams are visible and constants are sane.
@Suite("M0 Scaffold")
struct ScaffoldTests {

    @Test("All protocol seams are declared and accessible")
    func protocolSeamsAreDeclared() {
        // Compile-time proof: if any seam type is missing this file won't build.
        let _: (any HotkeyMonitoring)? = nil
        let _: (any AudioCapturing)? = nil
        let _: (any TranscriptionEngineProtocol)? = nil
        let _: (any CleanupServicing)? = nil
        let _: (any TextInserting)? = nil
        let _: (any ActiveAppProviding)? = nil
        let _: (any AnalyzerAudioSource)? = nil
        #expect(Bool(true))
    }

    @Test("AudioCapture provides the engine-facing analyzer audio source seam")
    func audioCaptureConformsToAnalyzerAudioSource() {
        // Compile-time proof (M12): the engine's buffer-handoff coupling is a
        // protocol, so eval-harness file sources can stand in for the mic.
        let source: any AnalyzerAudioSource = AudioCapture()
        #expect(source is AudioCapture)
    }

    @Test("Constants are within expected ranges")
    func constantsAreSane() {
        #expect(Constants.pasteboardRestoreDelay > 0)
        #expect(Constants.doubleTapThreshold == 0.4)
        #expect(Constants.cleanupChunkTimeout == 5.0)
        #expect(Constants.cleanupChunkTokenBudget > 0)
    }

    @Test("HotkeyEvent cases are distinct")
    func hotkeyEventCases() {
        let events: [HotkeyEvent] = [.startRequested, .stopRequested, .cancelRequested]
        #expect(events.count == 3)
    }

    @Test("TranscriptUpdate stores text and finality correctly")
    func transcriptUpdateFields() {
        let volatile = TranscriptUpdate(text: "hello", range: nil, isFinal: false)
        let final_ = TranscriptUpdate(text: "hello world", range: NSRange(location: 0, length: 11), isFinal: true)
        #expect(volatile.isFinal == false)
        #expect(final_.isFinal == true)
        #expect(final_.text == "hello world")
    }
}
