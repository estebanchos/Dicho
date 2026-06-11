import Foundation

/// Protocol seam for the Foundation Models cleanup pass. Production type: `CleanupService`.
///
/// Contract (golden-file tested): remove filler words, apply explicit self-corrections,
/// fix light punctuation. FORBIDDEN: paraphrase, summarize, translate, change register,
/// modify identifiers/numbers/URLs. Output is cleaned text only — no commentary.
///
/// If Foundation Models is unavailable (Apple Intelligence off, model not ready),
/// the implementation must throw `CleanupError.unavailable` so the coordinator
/// can fall back to the raw transcript.
protocol CleanupServicing: AnyObject, Sendable {
    /// Cleans a single text chunk. Throws `CleanupError` on unavailability or timeout.
    func clean(_ text: String) async throws -> String
}

/// Errors surfaced by `CleanupServicing` implementations.
enum CleanupError: Error, Sendable {
    /// Foundation Models is not available on this device or configuration.
    case unavailable
    /// The cleanup request exceeded the per-chunk timeout.
    case timeout
}
