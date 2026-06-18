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

    /// Resolves a bundle identifier to a category. Comparison is case-insensitive
    /// (macOS bundle IDs are conventionally case-sensitive but vendors occasionally
    /// ship variants); unknown or nil identifiers fall back to `.generalWriting`,
    /// which produces no hint in the cleanup prompt.
    ///
    /// Prefix-matched entries (e.g. `com.jetbrains.`) cover suite members without
    /// enumerating every IDE; version-suffixed entries (e.g. `com.finaldraft.FinalDraft12`)
    /// can be extended opportunistically as new bundle IDs are encountered.
    static func from(bundleIdentifier: String?) -> AppCategory {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return .generalWriting }
        let id = bundleIdentifier.lowercased()

        for entry in exactMatchTable where id == entry.identifier.lowercased() {
            return entry.category
        }
        for entry in prefixMatchTable where id.hasPrefix(entry.prefix.lowercased()) {
            return entry.category
        }
        return .generalWriting
    }

    // MARK: - Mapping tables

    private struct ExactEntry { let identifier: String; let category: AppCategory }
    private struct PrefixEntry { let prefix: String; let category: AppCategory }

    private static let exactMatchTable: [ExactEntry] = [
        // IDE
        .init(identifier: "com.apple.dt.Xcode", category: .ide),
        .init(identifier: "com.microsoft.VSCode", category: .ide),
        .init(identifier: "com.todesktop.230313mzl4w4u92", category: .ide), // Cursor
        .init(identifier: "com.sublimetext.4", category: .ide),
        // Terminal
        .init(identifier: "com.apple.Terminal", category: .terminal),
        .init(identifier: "com.googlecode.iterm2", category: .terminal),
        .init(identifier: "com.warp.dev", category: .terminal),
        .init(identifier: "com.mitchellh.ghostty", category: .terminal),
        // Messaging
        .init(identifier: "com.apple.MobileSMS", category: .messaging),
        .init(identifier: "com.tinyspeck.slackmacgap", category: .messaging),
        .init(identifier: "com.hnc.Discord", category: .messaging),
        .init(identifier: "org.telegram.desktop", category: .messaging),
        .init(identifier: "ru.keepcoder.Telegram", category: .messaging),
        // Email
        .init(identifier: "com.apple.mail", category: .email),
        .init(identifier: "com.microsoft.Outlook", category: .email),
        .init(identifier: "com.readdle.smartemail-Mac", category: .email),
        // Browser
        .init(identifier: "com.apple.Safari", category: .browser),
        .init(identifier: "com.google.Chrome", category: .browser),
        .init(identifier: "org.mozilla.firefox", category: .browser),
        .init(identifier: "company.thebrowser.Browser", category: .browser), // Arc
        .init(identifier: "com.brave.Browser", category: .browser),
        // Notes
        .init(identifier: "com.apple.Notes", category: .notes),
        .init(identifier: "md.obsidian", category: .notes),
        .init(identifier: "net.shinyfrog.bear", category: .notes),
        .init(identifier: "notion.id", category: .notes),
        // Script writing — bundle IDs verified opportunistically; version suffix may drift
        .init(identifier: "com.finaldraft.FinalDraft12", category: .scriptWriting),
        .init(identifier: "com.quoteunquoteapps.highland2", category: .scriptWriting),
        .init(identifier: "com.kentcomputers.fadein", category: .scriptWriting),
        .init(identifier: "com.bronson1980.Slugline2", category: .scriptWriting),
        // Film editing — version suffix may drift, especially for Adobe
        .init(identifier: "com.blackmagic-design.DaVinciResolve", category: .filmEditing),
        .init(identifier: "com.apple.FinalCut", category: .filmEditing),
        .init(identifier: "com.avid.AvidMediaComposer", category: .filmEditing),
        .init(identifier: "com.adobe.PremierePro", category: .filmEditing),
    ]

    private static let prefixMatchTable: [PrefixEntry] = [
        // JetBrains suite (IntelliJ IDEA, PyCharm, WebStorm, RubyMine, etc.)
        .init(prefix: "com.jetbrains.", category: .ide),
        // Adobe Premiere ships version-suffixed bundle IDs (e.g. com.adobe.PremierePro.24)
        .init(prefix: "com.adobe.PremierePro.", category: .filmEditing),
        // Final Draft ships version-suffixed bundle IDs across major releases
        .init(prefix: "com.finaldraft.FinalDraft", category: .scriptWriting),
    ]
}
