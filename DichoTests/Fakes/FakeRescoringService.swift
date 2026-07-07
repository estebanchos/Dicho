import Foundation
@testable import Dicho

/// Fake `RescoringServicing` for coordinator tests. Default behavior mirrors
/// production pass-through reassembly (trim each segment, join with single
/// spaces) so pre-rescoring coordinator assertions stay green; set
/// `stubbedResult` to observe rescored text flowing through the pipeline.
@MainActor
final class FakeRescoringService: RescoringServicing {

    private(set) var prewarmCount = 0
    private(set) var rescoreCallCount = 0
    private(set) var lastSegments: [TranscriptUpdate] = []

    /// When non-nil, returned from `rescore` instead of the pass-through join.
    var stubbedResult: String?

    func prewarm() {
        prewarmCount += 1
    }

    func rescore(_ segments: [TranscriptUpdate]) async -> String {
        rescoreCallCount += 1
        lastSegments = segments
        if let stubbedResult { return stubbedResult }
        return segments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
