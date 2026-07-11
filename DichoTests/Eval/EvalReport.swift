import CryptoKit
import Foundation
@testable import Dicho

/// M12.6 report model + writer. One `run.json` + `summary.md` per eval run,
/// written under `EvalResults/<timestamp>-<label>/` (gitignored).

struct RepeatTimings: Codable, Equatable {
    /// Stop → rescoring entry (engine drain + finalization).
    let finalizeSeconds: Double
    let rescoreSeconds: Double
    let cleanupSeconds: Double
    /// Stop → insertion — the user-felt latency.
    let totalSeconds: Double
}

struct RepeatRecord: Codable {
    let repeatIndex: Int
    let cleaned: String
    let rawTopJoin: String
    let rescored: String
    let deviations: [EvalDeviation]
    let timings: RepeatTimings
    let gateFirings: Int
    let segmentCount: Int

    var recoverableMajors: Int {
        deviations.count { $0.severity == .major && $0.layer != .asrCeiling }
    }
    var ceilingMajors: Int {
        deviations.count { $0.severity == .major && $0.layer == .asrCeiling }
    }
    var minors: Int {
        deviations.count { $0.severity == .minor }
    }
}

struct FixtureVariantResult: Codable {
    let fixtureID: String
    /// "recorded" or "tts:<voice>".
    let variant: String
    let tags: [String]
    let isLong: Bool
    let expectedWordCount: Int
    let repeats: [RepeatRecord]

    /// Comparator key: a change that hurts only one audio variant must veto.
    var aggregateKey: String { "\(fixtureID)@\(variant)" }
    var isTuning: Bool { tags.contains("tuning") }

    var latencies: [Double] { repeats.map(\.timings.totalSeconds) }
    var latencyMedian: Double {
        let sorted = latencies.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted.count.isMultiple(of: 2)
            ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
            : sorted[sorted.count / 2]
    }
    var latencyMax: Double { latencies.max() ?? 0 }

    func fixtureAggregate() -> FixtureAggregate {
        FixtureAggregate(
            fixtureID: aggregateKey,
            isLong: isLong,
            worstRunRecoverableMajors: repeats.map(\.recoverableMajors).max() ?? 0,
            ceilingMajors: repeats.map(\.ceilingMajors).max() ?? 0,
            minors: repeats.map(\.minors).max() ?? 0,
            expectedWordCount: expectedWordCount,
            latencyMedian: latencyMedian,
            latencyMax: latencyMax
        )
    }
}

struct ConfigFingerprint: Codable {
    let timestamp: String
    let gitCommit: String
    let label: String
    let repeats: Int
    let audioMode: String
    let constants: [String: String]
    let cleanupInstructionsChars: Int
    let cleanupInstructionsHash: String
    let rescoringInstructionsChars: Int
    let rescoringInstructionsHash: String

    @MainActor
    static func capture(label: String, repeats: Int, audioMode: String) -> ConfigFingerprint {
        let cleanupInstructions = CleanupService.buildInstructions(for: nil)
        let rescoringInstructions = RescoringService.buildInstructions()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return ConfigFingerprint(
            timestamp: formatter.string(from: Date()),
            gitCommit: currentGitCommit(),
            label: label,
            repeats: repeats,
            audioMode: audioMode,
            constants: [
                "rescoringConfidenceThreshold": String(Constants.rescoringConfidenceThreshold),
                "rescoringSegmentTimeout": String(Constants.rescoringSegmentTimeout),
                "rescoringMaxConcurrentSelections": String(Constants.rescoringMaxConcurrentSelections),
                "cleanupChunkTimeout": String(Constants.cleanupChunkTimeout),
                "cleanupChunkTokenBudget": String(Constants.cleanupChunkTokenBudget),
                "cleanupMinWordsForCleanup": String(Constants.cleanupMinWordsForCleanup),
            ],
            cleanupInstructionsChars: cleanupInstructions.count,
            cleanupInstructionsHash: sha256Prefix(cleanupInstructions),
            rescoringInstructionsChars: rescoringInstructions.count,
            rescoringInstructionsHash: sha256Prefix(rescoringInstructions)
        )
    }

    private static func sha256Prefix(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(12)
            .lowercased()
    }

    private static func currentGitCommit() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", EvalPaths.repoRoot.path, "rev-parse", "--short", "HEAD"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return "unknown"
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
    }
}

struct EvalRunReport: Codable {
    let fingerprint: ConfigFingerprint
    let results: [FixtureVariantResult]
    let skippedVariants: [String]

    /// Variants that run and report in full but never gate accept/reject
    /// (developer decision 2026-07-11, 12.8 baseline review): the developer's
    /// real voice behaves like Samantha, while Paulina overstates the accent
    /// penalty ~10x (105 vs 20 ceiling majors) — gating on it would tune
    /// against synthetic noise. It stays in every run as the rescoring-gate
    /// stress signal and an overfitting tripwire.
    static let reportedOnlyVariants: Set<String> = ["tts:Paulina"]

    /// Drives accept/reject and targets — tuning-tagged fixtures, minus the
    /// reported-only variants.
    var tuningAggregate: RunAggregate {
        RunAggregate(fixtures: results.filter(\.isGating).map { $0.fixtureAggregate() })
    }
    /// Overfitting tripwire — reported, never gates (holdout-tagged fixtures
    /// + reported-only variants).
    var holdoutAggregate: RunAggregate {
        RunAggregate(fixtures: results.filter { !$0.isGating }.map { $0.fixtureAggregate() })
    }
}

extension FixtureVariantResult {
    /// Whether this fixture-variant participates in the tuning gate.
    var isGating: Bool {
        isTuning && !EvalRunReport.reportedOnlyVariants.contains(variant)
    }
}

enum EvalReportWriter {

    /// Writes run.json + summary.md; returns the run directory.
    static func write(_ report: EvalRunReport, verdictSection: String?) throws -> URL {
        let directory = EvalPaths.resultsDirectory
            .appendingPathComponent("\(report.fingerprint.timestamp)-\(report.fingerprint.label)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: directory.appendingPathComponent("run.json"))

        var summary = renderSummary(report)
        if let verdictSection {
            summary += "\n" + verdictSection
        }
        try summary.write(
            to: directory.appendingPathComponent("summary.md"),
            atomically: true,
            encoding: .utf8
        )
        return directory
    }

    static func renderSummary(_ report: EvalRunReport) -> String {
        let f = report.fingerprint
        var lines: [String] = []
        lines.append("# Eval run \(f.timestamp) — \(f.label)")
        lines.append("")
        lines.append("- commit `\(f.gitCommit)` · repeats \(f.repeats) · audio \(f.audioMode)")
        lines.append("- cleanup instructions: \(f.cleanupInstructionsChars) chars `\(f.cleanupInstructionsHash)`")
        lines.append("- rescoring instructions: \(f.rescoringInstructionsChars) chars `\(f.rescoringInstructionsHash)`")
        lines.append("- constants: " + f.constants.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
        if !report.skippedVariants.isEmpty {
            lines.append("- skipped (no audio): \(report.skippedVariants.joined(separator: ", "))")
        }
        lines.append("")

        let tuning = report.tuningAggregate
        lines.append("## Aggregate (tuning fixtures)")
        lines.append("- recoverable majors (worst-run): **\(tuning.totalRecoverableMajors)** · ceiling majors: \(tuning.totalCeilingMajors)")
        lines.append(String(format: "- minors: %d (%.2f per 100 words)", tuning.totalMinors, tuning.minorsPer100Words))
        lines.append(String(format: "- latency median-sum: %.2fs", tuning.latencyMedianSum))
        let holdout = report.holdoutAggregate
        if !holdout.fixtures.isEmpty {
            lines.append("- holdout: \(holdout.totalRecoverableMajors) recoverable majors, \(holdout.totalMinors) minors")
        }
        lines.append("")

        lines.append("## Per fixture-variant")
        lines.append("| fixture@variant | maj(rec) | maj(ceil) | minors | lat p50 | lat max | gate firings |")
        lines.append("|---|---|---|---|---|---|---|")
        for result in report.results {
            let aggregate = result.fixtureAggregate()
            let firings = result.repeats.map { String($0.gateFirings) }.joined(separator: "/")
            lines.append(String(
                format: "| %@ | %d | %d | %d | %.2fs | %.2fs | %@ |",
                result.aggregateKey,
                aggregate.worstRunRecoverableMajors,
                aggregate.ceilingMajors,
                aggregate.minors,
                aggregate.latencyMedian,
                aggregate.latencyMax,
                firings
            ))
        }
        lines.append("")

        lines.append("## Deviations (worst repeat per fixture-variant)")
        for result in report.results {
            guard let worst = result.repeats.max(by: {
                ($0.recoverableMajors, $0.minors) < ($1.recoverableMajors, $1.minors)
            }), !worst.deviations.isEmpty else { continue }
            lines.append("### \(result.aggregateKey) (repeat \(worst.repeatIndex))")
            for deviation in worst.deviations {
                let layer = deviation.layer.map { " [\($0.rawValue)]" } ?? ""
                let expected = deviation.expected.map { "expected `\($0)`" }
                let actual = deviation.actual.map { "got `\($0)`" }
                let payload = [expected, actual].compactMap(\.self).joined(separator: ", ")
                lines.append("- \(deviation.severity.rawValue) \(deviation.kind.rawValue)\(layer): \(payload)")
            }
            lines.append("- cleaned: “\(worst.cleaned)”")
            lines.append("")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
