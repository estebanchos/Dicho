import Foundation
@testable import Dicho

/// Scripted fake selector session for `RescoringService` tests.
///
/// Behaviors are consumed one per `respondCandidateIndex(to:)` call, in order;
/// once exhausted the last behavior repeats. Records every prompt received and
/// how many times it was prewarmed.
@MainActor
final class FakeRescoringModelSession: RescoringModelSessioning {

    /// A scripted per-call outcome.
    enum Behavior {
        /// Return the given candidate index.
        case returnIndex(Int)
        /// Throw an arbitrary error (selector must fall back to top hypothesis).
        case throwError
        /// Await a long, cancellable sleep so the per-segment timeout wins.
        case sleepForever
    }

    private struct ScriptedError: Error {}

    private let behaviors: [Behavior]
    private var callIndex = 0

    private(set) var prompts: [String] = []
    private(set) var prewarmCount = 0

    init(_ behaviors: [Behavior]) {
        self.behaviors = behaviors
    }

    func prewarm() {
        prewarmCount += 1
    }

    func respondCandidateIndex(to prompt: String) async throws -> Int {
        prompts.append(prompt)
        let behavior = callIndex < behaviors.count ? behaviors[callIndex] : behaviors[behaviors.count - 1]
        callIndex += 1

        switch behavior {
        case .returnIndex(let index):
            return index
        case .throwError:
            throw ScriptedError()
        case .sleepForever:
            try await Task.sleep(for: .seconds(3600))
            return 0
        }
    }
}

/// Counting factory handing out scripted `FakeRescoringModelSession`s in order.
@MainActor
final class FakeRescoringSessionFactory {
    private var queued: [FakeRescoringModelSession]

    private(set) var sessionsCreated = 0

    init(_ sessions: [FakeRescoringModelSession]) {
        self.queued = sessions
    }

    /// Dequeues the next scripted session; falls back to a session that always
    /// picks index 0 so tests fail on count assertions rather than crashing.
    func make(_ instructions: String) -> any RescoringModelSessioning {
        sessionsCreated += 1
        if queued.isEmpty {
            return FakeRescoringModelSession([.returnIndex(0)])
        }
        return queued.removeFirst()
    }
}
