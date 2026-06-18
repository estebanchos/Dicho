import Foundation

/// Information about the frontmost application at the moment dictation stops.
///
/// Captured synchronously on `@MainActor` so that `NSRunningApplication`'s
/// time-varying properties (only fresh within the current main-run-loop turn)
/// are read promptly. Passed to `CleanupServicing.clean(_:appContext:)` to
/// shape the cleanup prompt with a target-app hint.
struct AppContext: Sendable, Equatable {
    let bundleIdentifier: String?
    let localizedName: String?
    let category: AppCategory
}

/// Coarse-grained categorization of the frontmost app. Drives the cleanup
/// prompt hint. Unknown or nil bundle identifiers map to `.generalWriting`,
/// which adds no hint and produces a prompt identical to the no-context baseline.
enum AppCategory: Sendable, Equatable, CaseIterable {
    case ide
    case terminal
    case messaging
    case email
    case browser
    case notes
    case scriptWriting
    case filmEditing
    case generalWriting
}
