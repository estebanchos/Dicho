import Foundation

/// Production text inserter: pasteboard save → set text → synthetic Cmd+V → restore.
/// Full implementation in M4. For M3 this logs the transcript to console only.
///
/// - Note: `@unchecked Sendable` — all mutable state will be confined to an
///   internal serial queue added in M4. For M3 the type is stateless.
final class TextInserter: TextInserting, @unchecked Sendable {
    func insert(_ text: String) async throws {
#if DEBUG
        print("[DEBUG] TextInserter (stub) — transcript: \(text)")
#endif
    }
}
