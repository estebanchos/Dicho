import AVFoundation
import Speech

/// Engine-facing seam for the audio-buffer handoff into `SpeechAnalyzer`.
///
/// `TranscriptionEngine.start()` creates each session's `AnalyzerInput` stream
/// and registers its continuation — plus the audio format the analyzer
/// requires — with its audio source through this protocol BEFORE capture
/// starts; buffers yielded before registration would be silently dropped
/// (see the startup-ordering contract in ARCHITECTURE.md).
///
/// Kept SEPARATE from the coordinator-facing `AudioCapturing` on purpose:
/// this protocol names Speech/AVFoundation types, and folding it into
/// `AudioCapturing` would drag those imports into the coordinator-test
/// fakes, which the repo convention forbids (coordinator tests never import
/// Speech/AVFoundation). Production conformer: `AudioCapture` (microphone).
/// Eval-harness conformer (M12): `FileAudioCapture` in `DichoTests/Eval/`
/// (fixture audio files, 1×-paced).
protocol AnalyzerAudioSource: AnyObject, Sendable {
    /// Registers the new session's continuation and target audio format.
    /// Called by `TranscriptionEngine.start()` exactly once per session.
    func beginSession(continuation: AsyncStream<AnalyzerInput>.Continuation, format: AVAudioFormat)
}
