import Foundation

/// M12 eval-harness fixture manifest — mirrors `EvalFixtures/manifests/*.json`.
/// Required fields have no defaults, so a malformed manifest fails loudly at
/// decode time (covered by `EvalManifestTests` in the gate).
struct EvalManifest: Codable, Equatable {
    struct TTSVariant: Codable, Equatable {
        let voice: String
        let file: String
    }

    struct Audio: Codable, Equatable {
        let recorded: String?
        let tts: [TTSVariant]
    }

    let id: String
    let phenomenon: String
    /// Long-form fixture (own latency bars; exercises chunking). Optional in
    /// JSON — absent means false.
    let long: Bool?
    let spoken: String
    let expected: String
    let mustContain: [String]
    let mustNotContain: [String]
    let tags: [String]
    let audio: Audio

    var isLong: Bool { long ?? false }
    var isTuning: Bool { tags.contains("tuning") }
}

/// Repo-relative paths for the harness, derived from `#filePath` — the eval
/// runner executes inside the hosted test bundle, whose working directory is
/// unrelated to the repo.
enum EvalPaths {
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)          // …/DichoTests/Eval/EvalManifest.swift
            .deletingLastPathComponent()         // …/DichoTests/Eval
            .deletingLastPathComponent()         // …/DichoTests
            .deletingLastPathComponent()         // repo root
    }

    static var fixturesDirectory: URL { repoRoot.appendingPathComponent("EvalFixtures") }
    static var manifestsDirectory: URL { fixturesDirectory.appendingPathComponent("manifests") }
    static var resultsDirectory: URL { repoRoot.appendingPathComponent("EvalResults") }
    static var targetsFile: URL { fixturesDirectory.appendingPathComponent("targets.json") }
    static var baselineFile: URL { resultsDirectory.appendingPathComponent("baseline.json") }

    /// Loads all committed manifests, sorted by id; `ids` filters when given.
    static func loadManifests(ids: [String]? = nil) throws -> [EvalManifest] {
        let files = try FileManager.default
            .contentsOfDirectory(at: manifestsDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        let decoder = JSONDecoder()
        var manifests = try files.map { try decoder.decode(EvalManifest.self, from: Data(contentsOf: $0)) }
        if let ids {
            manifests = manifests.filter { ids.contains($0.id) }
        }
        return manifests.sorted { $0.id < $1.id }
    }

    /// Absolute URL for an audio path stored fixture-relative in a manifest.
    static func audioURL(_ relativePath: String) -> URL {
        fixturesDirectory.appendingPathComponent(relativePath)
    }
}
