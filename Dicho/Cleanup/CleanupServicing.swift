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
    /// Cleans a transcript. Throws `CleanupError` on unavailability or timeout.
    ///
    /// `appContext` is captured by the coordinator at stop time. When non-nil and
    /// its category has an associated hint (anything other than `.generalWriting`),
    /// implementations append the hint to the session instructions to bias cleanup
    /// for the target app. The forbidden-actions contract is never overridden.
    func clean(_ text: String, appContext: AppContext?) async throws -> String

    /// Creates a warm `LanguageModelSession` in preparation for the next dictation.
    /// Call at recording start to reduce latency between stop and insertion.
    /// No-op when Foundation Models is unavailable.
    ///
    /// Prewarm runs before the user has finished speaking, so the app context is
    /// not yet known; implementations should build a no-context (baseline) session.
    /// `clean(_:appContext:)` rebuilds the session if context-aware instructions
    /// are needed by the time the transcript arrives.
    func prewarm()
}

/// Errors surfaced by `CleanupServicing` implementations.
enum CleanupError: Error, Sendable {
    /// Foundation Models is not available on this device or configuration.
    case unavailable
    /// The cleanup request exceeded the per-chunk timeout.
    case timeout
}
