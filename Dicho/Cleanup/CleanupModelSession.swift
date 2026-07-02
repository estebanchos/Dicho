import Foundation
import FoundationModels

/// Local error the session wrapper maps FoundationModels failures onto, so
/// `CleanupService`'s reuse/overflow/timeout control flow — and its tests —
/// never touch FoundationModels error types.
enum CleanupSessionError: Error, Sendable {
    /// The session reached its context-window token limit. `CleanupService`
    /// responds by rotating to a fresh session and retrying the chunk once.
    case contextWindowExceeded
}

/// Thin seam over one `LanguageModelSession` so `CleanupService`'s
/// shared-session reuse, per-chunk timeout, and rotation logic are unit-testable
/// without live FoundationModels calls (fakes conform in `DichoTests/Fakes/`).
///
/// `Sendable` is required so an existential `any CleanupModelSessioning` can be
/// captured by the child tasks of the per-chunk timeout race; all conformers are
/// `@MainActor` classes, which are implicitly `Sendable`.
@MainActor
protocol CleanupModelSessioning: AnyObject, Sendable {
    /// Warms the underlying session to reduce first-response latency.
    func prewarm()

    /// Runs one cleanup turn on the session. The session is stateful: prior
    /// turns in the same instance remain in context, which is what gives cleanup
    /// cross-chunk continuity.
    ///
    /// Throws `CleanupSessionError.contextWindowExceeded` when the session's
    /// token window overflows; rethrows every other error unchanged.
    func respondCleanedText(to prompt: String) async throws -> String
}

/// Production `CleanupModelSessioning` wrapping a single `LanguageModelSession`
/// with guided generation into `CleanedText`.
@MainActor
final class FoundationModelCleanupSession: CleanupModelSessioning {
    private let session: LanguageModelSession

    init(instructions: String) {
        session = LanguageModelSession(instructions: instructions)
    }

    func prewarm() {
        session.prewarm()
    }

    func respondCleanedText(to prompt: String) async throws -> String {
        do {
            // Greedy sampling: cleanup is a deterministic transformation, and the
            // default random sampling made rule application vary run-to-run
            // (Apple recommends greedy for deterministic output — WWDC25 301).
            return try await session.respond(
                to: prompt,
                generating: CleanedText.self,
                options: GenerationOptions(sampling: .greedy)
            ).content.text
        } catch let error as LanguageModelSession.GenerationError {
            if case .exceededContextWindowSize = error {
                throw CleanupSessionError.contextWindowExceeded
            }
            throw error
        }
    }
}
