import Foundation

/// Errors emitted by an audio capture session while active.
enum AudioCaptureError: Error, Sendable {
    case deviceLost
    case permissionRevoked
}

/// Protocol seam for microphone audio capture. Production type: `AudioCapture`.
///
/// The production implementation uses `AVAudioEngine` to tap the input node,
/// converts buffers to SpeechTranscriber's required format, and feeds them
/// to the `TranscriptionEngine`. The coordinator interacts only via
/// `startCapture()` / `stopCapture()`; buffer routing is internal to the
/// production types.
protocol AudioCapturing: AnyObject, Sendable {
    /// Errors emitted while capture is active (device lost, permission revoked).
    /// The coordinator monitors this stream during recording.
    var errors: AsyncStream<AudioCaptureError> { get }

    /// Begins capturing audio from the default input device.
    /// Throws if microphone permission is denied or the device is unavailable.
    func startCapture() throws

    /// Stops capture and tears down the audio engine tap.
    func stopCapture()
}
