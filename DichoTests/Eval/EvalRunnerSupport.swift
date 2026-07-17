import Foundation
@testable import Dicho

extension Duration {
    /// Seconds as a Double, for report serialization.
    var evalSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// Timing + payload capture around the real `RescoringService`, measured at
/// the protocol seam — zero edits to the production service (M12.6).
@MainActor
final class TimingRescoringService: RescoringServicing {
    private let wrapped: any RescoringServicing
    private let clock = ContinuousClock()

    private(set) var capturedSegments: [TranscriptUpdate] = []
    private(set) var output: String?
    private(set) var startedAt: ContinuousClock.Instant?
    private(set) var finishedAt: ContinuousClock.Instant?

    init(wrapping wrapped: any RescoringServicing) {
        self.wrapped = wrapped
    }

    func prewarm() {
        wrapped.prewarm()
    }

    func rescore(_ segments: [TranscriptUpdate]) async -> String {
        capturedSegments = segments
        startedAt = clock.now
        let result = await wrapped.rescore(segments)
        finishedAt = clock.now
        output = result
        return result
    }
}

/// Timing + payload capture around the real `CleanupService` (same
/// @MainActor-class-conforming-to-Sendable-protocol pattern as production).
@MainActor
final class TimingCleanupService: CleanupServicing {
    private let wrapped: any CleanupServicing
    private let clock = ContinuousClock()

    private(set) var input: String?
    private(set) var output: String?
    private(set) var startedAt: ContinuousClock.Instant?
    private(set) var finishedAt: ContinuousClock.Instant?

    init(wrapping wrapped: any CleanupServicing) {
        self.wrapped = wrapped
    }

    func prewarm() {
        wrapped.prewarm()
    }

    func clean(_ text: String, appContext: AppContext?) async throws -> String {
        input = text
        startedAt = clock.now
        defer { finishedAt = clock.now }
        let result = try await wrapped.clean(text, appContext: appContext)
        output = result
        return result
    }
}

/// Terminal capture: records what the pipeline would have pasted, and when.
/// Never touches the pasteboard or posts events.
@MainActor
final class CollectingTextInserter: TextInserting {
    private let clock = ContinuousClock()

    private(set) var insertedText: String?
    private(set) var insertedAt: ContinuousClock.Instant?

    func insert(_ text: String) async throws {
        insertedText = text
        insertedAt = clock.now
    }
}
