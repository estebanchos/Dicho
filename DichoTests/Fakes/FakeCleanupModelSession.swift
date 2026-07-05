import Foundation
@testable import Dicho

/// Scripted fake session for `CleanupService`'s shared-session loop tests.
///
/// Behaviors are consumed one per `respondCleanedText(to:)` call, in order; once
/// the script is exhausted the last behavior repeats (so a session that only ever
/// succeeds needs a single `.succeed` entry). Records every prompt it received and
/// how many times it was prewarmed.
@MainActor
final class FakeCleanupModelSession: CleanupModelSessioning {

    /// A scripted per-call outcome.
    enum Behavior {
        /// Return a cleaned string derived from the prompt.
        case succeed(@MainActor (String) -> String)
        /// Throw `CleanupSessionError.contextWindowExceeded` (window overflow).
        case throwOverflow
        /// Await a long, cancellable sleep so the per-chunk timeout wins the race.
        case sleepForever
        /// Return a string containing a schema-leakage marker (`"schema:"`).
        case succeedWithLeakage
        /// Throw `CleanupSessionError.guardrailTriggered` (safety guardrails
        /// refused the content).
        case throwGuardrail
        /// Throw an arbitrary error that is neither overflow nor timeout.
        case throwOther(Error)
    }

    private let behaviors: [Behavior]
    private var callIndex = 0

    private(set) var prompts: [String] = []
    private(set) var prewarmCount = 0

    init(_ behaviors: [Behavior]) {
        self.behaviors = behaviors
    }

    /// Convenience: a session that cleans every chunk by echoing the prompt's
    /// input line prefixed so tests can assert order.
    static func alwaysSucceeds(_ transform: @escaping @MainActor (String) -> String = { $0 }) -> FakeCleanupModelSession {
        FakeCleanupModelSession([.succeed(transform)])
    }

    func prewarm() {
        prewarmCount += 1
    }

    func respondCleanedText(to prompt: String) async throws -> String {
        prompts.append(prompt)
        let behavior = callIndex < behaviors.count ? behaviors[callIndex] : behaviors[behaviors.count - 1]
        callIndex += 1

        switch behavior {
        case .succeed(let transform):
            return transform(prompt)
        case .throwOverflow:
            throw CleanupSessionError.contextWindowExceeded
        case .sleepForever:
            try await Task.sleep(for: .seconds(3600))
            return ""
        case .succeedWithLeakage:
            return "schema: { name: CleanedText }"
        case .throwGuardrail:
            throw CleanupSessionError.guardrailTriggered
        case .throwOther(let error):
            throw error
        }
    }
}

/// Counting factory that hands out scripted `FakeCleanupModelSession`s in order.
///
/// Passed into `CleanupService` as its `makeSession` closure via `factory.make`.
/// Records how many sessions were created and the instruction string used for each.
@MainActor
final class FakeSessionFactory {
    private var queued: [FakeCleanupModelSession]

    private(set) var sessionsCreated = 0
    private(set) var instructionsUsed: [String] = []

    init(_ sessions: [FakeCleanupModelSession]) {
        self.queued = sessions
    }

    /// Dequeues the next scripted session. If the queue is exhausted, returns a
    /// fresh always-succeeds session so tests fail on the count assertion rather
    /// than crashing.
    func make(_ instructions: String) -> any CleanupModelSessioning {
        sessionsCreated += 1
        instructionsUsed.append(instructions)
        if queued.isEmpty {
            return FakeCleanupModelSession.alwaysSucceeds()
        }
        return queued.removeFirst()
    }
}
