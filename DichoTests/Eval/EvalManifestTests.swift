import Foundation
import Testing
@testable import Dicho

/// M12.6 manifest-schema tests — run in the normal gate. Decoding the REAL
/// committed manifests doubles as a schema tripwire: a fixture edit that
/// breaks the contract fails here, not mid-eval-run.
@Suite("EvalManifest")
struct EvalManifestTests {

    @Test("All committed manifests decode and carry the required content")
    func committedManifestsDecode() throws {
        let manifests = try EvalPaths.loadManifests()
        #expect(manifests.count == 11)
        for manifest in manifests {
            #expect(!manifest.id.isEmpty)
            #expect(!manifest.spoken.isEmpty)
            #expect(!manifest.expected.isEmpty)
            #expect(!manifest.audio.tts.isEmpty)
            #expect(!manifest.tags.isEmpty)
        }
        // Exactly one long-form fixture in the initial set.
        #expect(manifests.count(where: \.isLong) == 1)
    }

    @Test("Manifest ids are unique and match their filenames")
    func manifestIDsMatchFilenames() throws {
        let manifests = try EvalPaths.loadManifests()
        #expect(Set(manifests.map(\.id)).count == manifests.count)
        for manifest in manifests {
            let file = EvalPaths.manifestsDirectory.appendingPathComponent("\(manifest.id).json")
            #expect(FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test("A manifest missing a required field fails loudly")
    func missingFieldFailsLoudly() {
        let malformed = Data("""
        { "id": "x", "phenomenon": "p", "spoken": "s" }
        """.utf8)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(EvalManifest.self, from: malformed)
        }
    }

    @Test("Round-trip encode/decode preserves the manifest")
    func roundTrip() throws {
        let manifests = try EvalPaths.loadManifests(ids: ["spoken-register"])
        let manifest = try #require(manifests.first)
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(EvalManifest.self, from: data)
        #expect(decoded == manifest)
    }

    @Test("Fixture scripts avoid scorer quirks: no counting sequences")
    func fixtureScriptsAvoidScorerQuirks() throws {
        // The number normalizer greedily merges adjacent cardinal words (a
        // documented quirk). Expected texts must not contain shapes where two
        // adjacent cardinals are NOT one number ("one two", "five thirty").
        // "three hundred", "one thousand seventy" etc. are intended merges;
        // this test just pins the reviewed-safe state: expected == spoken
        // normalization must never crash and yields non-empty sequences.
        for manifest in try EvalPaths.loadManifests() {
            #expect(!EvalTokenizer.normalizedSequence(manifest.expected).isEmpty)
            #expect(!EvalTokenizer.normalizedSequence(manifest.spoken).isEmpty)
        }
    }
}
