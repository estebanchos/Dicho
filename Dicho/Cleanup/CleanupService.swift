import Foundation

/// Production cleanup service using Foundation Models (implemented in M5).
/// For M3–M4 this always throws `.unavailable`; coordinator falls back to the
/// raw transcript. `isRawMode: true` in M3 wiring means it is never called.
final class CleanupService: CleanupServicing, @unchecked Sendable {
    func clean(_ text: String) async throws -> String {
        throw CleanupError.unavailable
    }
}
