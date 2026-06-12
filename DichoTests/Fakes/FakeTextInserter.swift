import Foundation
@testable import Dicho

@MainActor
final class FakeTextInserter: TextInserting {
    private(set) var insertedText: String? = nil
    private(set) var insertCallCount = 0
    var stubbedError: Error? = nil

    func insert(_ text: String) async throws {
        insertCallCount += 1
        if let error = stubbedError { throw error }
        insertedText = text
    }
}
