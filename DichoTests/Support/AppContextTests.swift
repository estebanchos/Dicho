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
}
