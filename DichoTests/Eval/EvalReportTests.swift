import Foundation
import Testing
@testable import Dicho

/// M12.8 gating-rule tests — pure logic, run in the normal gate.
@Suite("EvalReportGating")
struct EvalReportTests {

    private func result(_ fixtureID: String, variant: String, tags: [String]) -> FixtureVariantResult {
        FixtureVariantResult(
            fixtureID: fixtureID,
            variant: variant,
            tags: tags,
            isLong: false,
            expectedWordCount: 10,
            repeats: []
        )
    }

    @Test("Gate = tuning-tagged fixtures minus reported-only variants")
    func gatingRule() {
        // 2026-07-12 instrument: developer's voice is the sole gating variant.
        #expect(result("a", variant: "recorded", tags: ["tuning"]).isGating)
        // The Maria canary never gates, even on a tuning fixture.
        #expect(!result("a", variant: "recorded:maria", tags: ["tuning"]).isGating)
        // Holdout-tagged fixtures never gate on any variant.
        #expect(!result("h", variant: "recorded", tags: ["holdout"]).isGating)
        #expect(!result("h", variant: "recorded:maria", tags: ["holdout"]).isGating)
    }

    @Test("Aggregates split along the gating rule")
    func aggregatesSplit() {
        let report = EvalRunReport(
            fingerprint: ConfigFingerprint(
                timestamp: "t", gitCommit: "c", label: "l", repeats: 1, audioMode: "both",
                constants: [:],
                cleanupInstructionsChars: 0, cleanupInstructionsHash: "",
                rescoringInstructionsChars: 0, rescoringInstructionsHash: ""
            ),
            results: [
                result("a", variant: "recorded", tags: ["tuning"]),
                result("a", variant: "recorded:maria", tags: ["tuning"]),
                result("h", variant: "recorded", tags: ["holdout"]),
            ],
            skippedVariants: []
        )
        #expect(report.tuningAggregate.fixtures.map(\.fixtureID) == ["a@recorded"])
        #expect(Set(report.holdoutAggregate.fixtures.map(\.fixtureID)) == ["a@recorded:maria", "h@recorded"])
    }

    @Test("Current fixture set gates 9 variants: 9 tuning fixtures x recorded only")
    func currentFixtureSetGatingCount() throws {
        let manifests = try EvalPaths.loadManifests()
        let tuning = manifests.filter(\.isTuning)
        let holdout = manifests.filter { !$0.isTuning }
        #expect(tuning.count == 9)
        #expect(holdout.map(\.id).sorted() == ["homophone-spelling", "tech-passthrough"])
    }
}
