import Testing
@testable import Dicho

/// Pure mapping from coordinator state + settings to the HUD's render phase
/// (M11). No SwiftUI, no coordinator — just the value-level decisions that
/// decide what the card shows.
@Suite("HUDView.phase — coordinator/settings → render phase (M11)")
struct HUDViewStateTests {

    @Test("Recording carries transcript, transcript-visibility, and raw flag")
    func recordingCarriesFlags() {
        let phase = HUDView.phase(
            state: .recording,
            finalized: "hello",
            volatile: " world",
            notice: nil,
            hudStyle: .fullTranscript,
            isRawMode: true)
        #expect(phase == .recording(finalized: "hello", volatile: " world", showTranscript: true, isRaw: true))
    }

    @Test("Icon-only HUD style hides the transcript while recording")
    func waveformOnlyHidesTranscript() {
        let phase = HUDView.phase(
            state: .recording,
            finalized: "hello",
            volatile: "",
            notice: nil,
            hudStyle: .waveformOnly,
            isRawMode: false)
        #expect(phase == .recording(finalized: "hello", volatile: "", showTranscript: false, isRaw: false))
    }

    @Test("Pipeline states map to their phases")
    func pipelineStatesMap() {
        #expect(HUDView.phase(state: .transcribing, finalized: "", volatile: "", notice: nil, hudStyle: .fullTranscript, isRawMode: false) == .transcribing)
        #expect(HUDView.phase(state: .cleaning(transcript: "x"), finalized: "", volatile: "", notice: nil, hudStyle: .fullTranscript, isRawMode: false) == .cleaning)
        #expect(HUDView.phase(state: .inserting(text: "x"), finalized: "", volatile: "", notice: nil, hudStyle: .fullTranscript, isRawMode: false) == .inserting)
    }

    @Test("Idle with an active notice shows that notice")
    func idleWithNoticeShowsNotice() {
        let phase = HUDView.phase(
            state: .idle,
            finalized: "",
            volatile: "",
            notice: .insertionFailed,
            hudStyle: .fullTranscript,
            isRawMode: false)
        #expect(phase == .notice(.insertionFailed))
    }

    @Test("Idle with no notice shows nothing")
    func idleWithoutNoticeIsHidden() {
        let phase = HUDView.phase(
            state: .idle,
            finalized: "",
            volatile: "",
            notice: nil,
            hudStyle: .fullTranscript,
            isRawMode: false)
        #expect(phase == nil)
    }
}
