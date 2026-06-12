import Foundation
@testable import Dicho

@MainActor
final class FakeCleanupService: CleanupServicing {
    var stubbedResult: String = "cleaned"
    var stubbedError: Error? = nil
    private(set) var cleanCallCount = 0
    private(set) var lastCleanedText: String? = nil

    func clean(_ text: String) async throws -> String {
        cleanCallCount += 1
        lastCleanedText = text
        if let error = stubbedError { throw error }
        return stubbedResult
    }
}
