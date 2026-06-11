import Foundation

/// Protocol seam for microphone audio capture. Production type: `AudioCapture`.
///
/// The production implementation uses `AVAudioEngine` to tap the input node,
/// converts buffers to SpeechTranscriber's required format, and feeds them
/// to the `TranscriptionEngine`. The coordinator interacts only via
/// `startCapture()` / `stopCapture()`; buffer routing is internal to the
/// production types.
protocol AudioCapturing: AnyObject, Sendable {
    /// Begins capturing audio from the default input device.
    /// Throws if microphone permission is denied or the device is unavailable.
    func startCapture() throws

    /// Stops capture and tears down the audio engine tap.
    func stopCapture()
}
