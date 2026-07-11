import AVFoundation
import Foundation
import Testing
@testable import Dicho

/// M12.6 eval runner — LIVE Speech + FoundationModels, structurally excluded
/// from the gate by the `.enabled(if:)` trait (same convention as
/// `EvalSpikeTests`). Invocation:
///
///     TEST_RUNNER_DICHO_EVAL=1 xcodebuild test -scheme Dicho \
///         -destination 'platform=macOS' -parallel-testing-enabled NO \
///         -only-testing:DichoTests/EvalRun
///
/// `-parallel-testing-enabled NO` is REQUIRED: without it xcodebuild spawns
/// two runner clones that execute the plan concurrently — duplicate reports
/// and FM-daemon contention that poisons every latency number (observed on
/// the 12.7 smoke run).
///
/// Environment configuration (all forwarded via the TEST_RUNNER_ prefix):
/// - DICHO_EVAL_FIXTURES  comma-separated fixture ids (default: all)
/// - DICHO_EVAL_REPEATS   repeats per fixture-variant (default: 3)
/// - DICHO_EVAL_AUDIO     recorded | tts | both (default: both)
/// - DICHO_EVAL_LABEL     run-directory suffix (default: "run")
///
/// Each repeat assembles a FRESH pipeline graph (fresh FM sessions, fresh
/// analyzer) and drives the real `DictationCoordinator` exactly like a user:
/// start → audio plays at 1× → stop at EOF → await insertion. Fixtures run
/// serially — the on-device FM daemon serializes generations, and parallel
/// runs would poison the latency numbers.
@MainActor
@Suite(
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["DICHO_EVAL"] == "1")
)
struct EvalRun {

    @Test func runEvalPlan() async throws {
        let environment = ProcessInfo.processInfo.environment
        let ids = environment["DICHO_EVAL_FIXTURES"].map {
            $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let repeats = environment["DICHO_EVAL_REPEATS"].flatMap(Int.init) ?? 3
        let audioMode = environment["DICHO_EVAL_AUDIO"] ?? "both"
        let label = environment["DICHO_EVAL_LABEL"] ?? "run"

        let manifests = try EvalPaths.loadManifests(ids: ids)
        try #require(!manifests.isEmpty, "no manifests matched DICHO_EVAL_FIXTURES")

        var results: [FixtureVariantResult] = []
        var skipped: [String] = []

        for manifest in manifests {
            for (variantName, relativePath) in Self.variants(of: manifest, mode: audioMode) {
                let audioURL = EvalPaths.audioURL(relativePath)
                guard FileManager.default.fileExists(atPath: audioURL.path) else {
                    skipped.append("\(manifest.id)@\(variantName)")
                    continue
                }
                var records: [RepeatRecord] = []
                for repeatIndex in 0..<repeats {
                    let record = await Self.runOnce(
                        manifest: manifest,
                        audioURL: audioURL,
                        repeatIndex: repeatIndex
                    )
                    print(String(
                        format: "[EVAL] %@@%@ #%d: recMaj=%d ceil=%d minors=%d total=%.2fs gate=%d",
                        manifest.id, variantName, repeatIndex,
                        record.recoverableMajors, record.ceilingMajors, record.minors,
                        record.timings.totalSeconds, record.gateFirings
                    ))
                    records.append(record)
                    // Breather between repeats so FM-daemon teardown from the
                    // previous graph can't bleed into the next one's timings.
                    try? await Task.sleep(for: .seconds(1))
                }
                results.append(FixtureVariantResult(
                    fixtureID: manifest.id,
                    variant: variantName,
                    tags: manifest.tags,
                    isLong: manifest.isLong,
                    expectedWordCount: manifest.expected.split(whereSeparator: \.isWhitespace).count,
                    repeats: records
                ))
            }
        }

        try #require(!results.isEmpty, "no fixture variant had audio — run generate_tts.sh or record first")

        let fingerprint = ConfigFingerprint.capture(label: label, repeats: repeats, audioMode: audioMode)
        let report = EvalRunReport(fingerprint: fingerprint, results: results, skippedVariants: skipped)
        let verdictSection = Self.verdictSection(for: report)
        let directory = try EvalReportWriter.write(report, verdictSection: verdictSection)

        let tuning = report.tuningAggregate
        print("[EVAL] recoverable majors: \(tuning.totalRecoverableMajors), ceiling: \(tuning.totalCeilingMajors), minors: \(tuning.totalMinors)")
        if let verdictSection {
            print("[EVAL] \(verdictSection.split(separator: "\n").joined(separator: " | "))")
        }
        print("[EVAL] report written: \(directory.path)")
    }

    // MARK: - One repeat

    private static func runOnce(
        manifest: EvalManifest,
        audioURL: URL,
        repeatIndex: Int
    ) async -> RepeatRecord {
        let clock = ContinuousClock()

        let capture = FileAudioCapture(fileURL: audioURL)
        let engine = TranscriptionEngine(audioSource: capture)
        let rescoring = TimingRescoringService(wrapping: RescoringService())
        let cleanup = TimingCleanupService(wrapping: CleanupService())
        let inserter = CollectingTextInserter()
        let coordinator = DictationCoordinator(
            hotkeyMonitor: FakeHotkeyMonitor(),
            audioCapture: capture,
            transcriptionEngine: engine,
            cleanupService: cleanup,
            textInserter: inserter,
            rescoringService: rescoring,
            activeAppProvider: nil,
            isRawMode: false
        )

        let (playbackDone, playbackContinuation) = AsyncStream<Void>.makeStream()
        capture.onPlaybackFinished = { playbackContinuation.finish() }

        await coordinator.handleHotkeyEvent(.startRequested)
        guard coordinator.state == .recording else {
            Issue.record("\(manifest.id) #\(repeatIndex): pipeline failed to start (state \(coordinator.state))")
            return failureRecord(manifest: manifest, repeatIndex: repeatIndex)
        }

        // Resolves when EOF + trailing silence have been fed — the analog of
        // the user tapping stop right after their last word.
        for await _ in playbackDone {}
        let stopInstant = clock.now
        // Returns only after the full stop → rescore → clean → insert chain.
        await coordinator.handleHotkeyEvent(.stopRequested)

        let segments = rescoring.capturedSegments
        let rawTopJoin = segments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let rescored = rescoring.output ?? ""
        let cleaned = inserter.insertedText ?? ""

        let deviations = EvalScorer.score(
            expected: manifest.expected,
            actual: cleaned,
            mustContain: manifest.mustContain,
            mustNotContain: manifest.mustNotContain,
            intermediates: EvalIntermediates(
                rawTopJoin: rawTopJoin,
                rescoredText: rescored,
                segments: segments
            )
        )

        let finalizeSeconds = rescoring.startedAt.map { stopInstant.duration(to: $0).evalSeconds } ?? 0
        let rescoreSeconds = zip(rescoring.startedAt, rescoring.finishedAt)
            .map { $0.0.duration(to: $0.1).evalSeconds } ?? 0
        let cleanupSeconds = zip(cleanup.startedAt, cleanup.finishedAt)
            .map { $0.0.duration(to: $0.1).evalSeconds } ?? 0
        let totalSeconds = inserter.insertedAt.map { stopInstant.duration(to: $0).evalSeconds } ?? 0

        return RepeatRecord(
            repeatIndex: repeatIndex,
            cleaned: cleaned,
            rawTopJoin: rawTopJoin,
            rescored: rescored,
            deviations: deviations,
            timings: RepeatTimings(
                finalizeSeconds: finalizeSeconds,
                rescoreSeconds: rescoreSeconds,
                cleanupSeconds: cleanupSeconds,
                totalSeconds: totalSeconds
            ),
            gateFirings: segments.count {
                RescoringGate.needsRescoring($0, threshold: Constants.rescoringConfidenceThreshold)
            },
            segmentCount: segments.count
        )
    }

    private static func failureRecord(manifest: EvalManifest, repeatIndex: Int) -> RepeatRecord {
        RepeatRecord(
            repeatIndex: repeatIndex,
            cleaned: "",
            rawTopJoin: "",
            rescored: "",
            deviations: EvalScorer.score(
                expected: manifest.expected,
                actual: "",
                mustContain: manifest.mustContain,
                mustNotContain: manifest.mustNotContain
            ),
            timings: RepeatTimings(finalizeSeconds: 0, rescoreSeconds: 0, cleanupSeconds: 0, totalSeconds: 0),
            gateFirings: 0,
            segmentCount: 0
        )
    }

    // MARK: - Variants + verdict

    private static func variants(of manifest: EvalManifest, mode: String) -> [(name: String, path: String)] {
        var list: [(String, String)] = []
        if mode != "tts", let recorded = manifest.audio.recorded {
            list.append(("recorded", recorded))
        }
        if mode != "recorded" {
            list += manifest.audio.tts.map { ("tts:\($0.voice)", $0.file) }
        }
        return list
    }

    /// When a promoted baseline and developer targets exist, appends the
    /// deterministic comparator verdict to the summary (PROTOCOL.md step 4).
    private static func verdictSection(for report: EvalRunReport) -> String? {
        guard let baselineData = try? Data(contentsOf: EvalPaths.baselineFile),
              let baseline = try? JSONDecoder().decode(EvalRunReport.self, from: baselineData)
        else { return nil }
        let targets = (try? Data(contentsOf: EvalPaths.targetsFile))
            .flatMap { try? JSONDecoder().decode(EvalTargets.self, from: $0) }
            ?? EvalTargets(
                maxRecoverableMajors: nil,
                maxMinorsPer100Words: nil,
                latencyShortP50: nil,
                latencyShortMax: nil,
                latencyLongP50: nil,
                latencyLongMax: nil
            )
        let verdict = EvalCompare.compare(
            baseline: baseline.tuningAggregate,
            candidate: report.tuningAggregate,
            targets: targets
        )
        var lines = ["## Verdict vs baseline (\(baseline.fingerprint.timestamp))"]
        lines.append(verdict.accepted ? "- **ACCEPT**" : "- **REJECT**")
        lines += verdict.reasons.map { "- \($0)" }
        lines.append("- targets met: \(EvalCompare.targetsMet(report.tuningAggregate, targets: targets))")
        return lines.joined(separator: "\n")
    }
}

/// `zip` for two optionals — keeps the timing derivations readable.
private func zip<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}
