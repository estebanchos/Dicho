import Foundation
import Testing
@testable import Dicho

@Suite("AppContext — value-type contract")
struct AppContextTests {

    @Test("Two AppContext values with identical fields are equal")
    func equalitySameFields() {
        let a = AppContext(bundleIdentifier: "com.apple.dt.Xcode", localizedName: "Xcode", category: .ide)
        let b = AppContext(bundleIdentifier: "com.apple.dt.Xcode", localizedName: "Xcode", category: .ide)
        #expect(a == b)
    }

    @Test("Different bundle identifiers produce non-equal values")
    func equalityDiffersOnBundleID() {
        let a = AppContext(bundleIdentifier: "com.apple.dt.Xcode", localizedName: "Xcode", category: .ide)
        let b = AppContext(bundleIdentifier: "com.apple.Terminal", localizedName: "Xcode", category: .ide)
        #expect(a != b)
    }

    @Test("Different categories produce non-equal values")
    func equalityDiffersOnCategory() {
        let a = AppContext(bundleIdentifier: "x", localizedName: "x", category: .ide)
        let b = AppContext(bundleIdentifier: "x", localizedName: "x", category: .terminal)
        #expect(a != b)
    }

    @Test("All AppCategory cases are represented in CaseIterable")
    func categoryAllCasesIncludesEveryCase() {
        // Acts as a tripwire: if a new case is added to AppCategory, this test
        // forces the developer to update the mapping/hint tables before shipping.
        let expected: Set<AppCategory> = [
            .ide, .terminal, .messaging, .email, .browser,
            .notes, .scriptWriting, .filmEditing, .generalWriting,
        ]
        #expect(Set(AppCategory.allCases) == expected)
    }

    // MARK: - Bundle-ID → category mapping (7.2)

    @Test("Nil bundle identifier maps to generalWriting")
    func nilMapsToGeneralWriting() {
        #expect(AppCategory.from(bundleIdentifier: nil) == .generalWriting)
    }

    @Test("Empty bundle identifier maps to generalWriting")
    func emptyMapsToGeneralWriting() {
        #expect(AppCategory.from(bundleIdentifier: "") == .generalWriting)
    }

    @Test("Unknown bundle identifier maps to generalWriting")
    func unknownMapsToGeneralWriting() {
        #expect(AppCategory.from(bundleIdentifier: "com.example.UnknownApp") == .generalWriting)
    }

    @Test(
        "Known bundle identifiers map to expected categories",
        arguments: [
            // IDE — exact
            ("com.apple.dt.Xcode", AppCategory.ide),
            ("com.microsoft.VSCode", .ide),
            ("com.todesktop.230313mzl4w4u92", .ide), // Cursor
            ("com.sublimetext.4", .ide),
            // IDE — JetBrains prefix
            ("com.jetbrains.intellij", .ide),
            ("com.jetbrains.pycharm", .ide),
            ("com.jetbrains.WebStorm", .ide),
            // Terminal
            ("com.apple.Terminal", .terminal),
            ("com.googlecode.iterm2", .terminal),
            ("com.warp.dev", .terminal),
            ("com.mitchellh.ghostty", .terminal),
            // Messaging
            ("com.apple.MobileSMS", .messaging),
            ("com.tinyspeck.slackmacgap", .messaging),
            ("com.hnc.Discord", .messaging),
            ("org.telegram.desktop", .messaging),
            ("ru.keepcoder.Telegram", .messaging),
            // Email
            ("com.apple.mail", .email),
            ("com.microsoft.Outlook", .email),
            ("com.readdle.smartemail-Mac", .email),
            // Browser
            ("com.apple.Safari", .browser),
            ("com.google.Chrome", .browser),
            ("org.mozilla.firefox", .browser),
            ("company.thebrowser.Browser", .browser),
            ("com.brave.Browser", .browser),
            // Notes
            ("com.apple.Notes", .notes),
            ("md.obsidian", .notes),
            ("net.shinyfrog.bear", .notes),
            ("notion.id", .notes),
            // Script writing — exact + Final Draft prefix
            ("com.finaldraft.FinalDraft12", .scriptWriting),
            ("com.finaldraft.FinalDraft13", .scriptWriting), // future major
            ("com.quoteunquoteapps.highland2", .scriptWriting),
            ("com.kentcomputers.fadein", .scriptWriting),
            ("com.bronson1980.Slugline2", .scriptWriting),
            // Film editing — exact + Premiere prefix
            ("com.blackmagic-design.DaVinciResolve", .filmEditing),
            ("com.apple.FinalCut", .filmEditing),
            ("com.avid.AvidMediaComposer", .filmEditing),
            ("com.adobe.PremierePro", .filmEditing),
            ("com.adobe.PremierePro.24", .filmEditing), // versioned variant
        ]
    )
    func knownBundleIDsMapAsExpected(_ pair: (String, AppCategory)) {
        let (id, expected) = pair
        #expect(AppCategory.from(bundleIdentifier: id) == expected)
    }

    @Test("Case-insensitive matching: uppercase variant maps the same way as the canonical form")
    func mappingIsCaseInsensitive() {
        #expect(AppCategory.from(bundleIdentifier: "COM.APPLE.DT.XCODE") == .ide)
        #expect(AppCategory.from(bundleIdentifier: "Com.Jetbrains.PyCharm") == .ide)
    }
}
