import Foundation
import Testing
@testable import Dicho

/// M17.3 ASR A/B live runner (`Documentation/asr_ab_plan.md` §3) — LIVE Speech
/// models, structurally excluded from the gate by the `.enabled(if:)` trait
/// (same convention as `EvalRun`/`EvalSpikeTests`). Invocation:
///
///     TEST_RUNNER_DICHO_ASR_AB=1 xcodebuild test -scheme Dicho \
///         -destination 'platform=macOS' -parallel-testing-enabled NO \
///         -only-testing:DichoTests/AsrABRun
///
/// `-parallel-testing-enabled NO` is REQUIRED for the same reason as `EvalRun`:
/// without it xcodebuild spawns two runner clones that execute the plan
/// concurrently — duplicate reports and FM/Speech-daemon contention that
/// poisons every latency and confidence number.
///
/// This runner is SIMPLER than `EvalRun`: there is no `DictationCoordinator`,
/// no `CleanupService`/`RescoringService`, no FoundationModels calls — each
/// arm's transcription engine is driven directly against a fresh
/// `FileAudioCapture`, and the metrics are computed straight off the raw
/// `TranscriptUpdate` stream via `AsrABScoring`.
///
/// Environment configuration (all forwarded via the TEST_RUNNER_ prefix):
/// - DICHO_ASR_AB_FIXTURES  comma-separated fixture ids (default: all)
/// - DICHO_ASR_AB_REPEATS   repeats per fixture-variant (default: 3)
/// - DICHO_ASR_AB_LABEL     run-directory suffix (default: "run"; the
///                          directory is named `<timestamp>-asr-ab-<label>`,
///                          so the "asr-ab" marker is always present)
/// - DICHO_ASR_AB_ARMS      comma-separated subset of
///                          baseline,dictation,dictation-ctx
///                          (default: "baseline,dictation")
///
/// Variants: human recordings only (TTS retired, per the M12.8/12.12 ruling
/// this runner inherits unchanged) — the developer's voice ("recorded", the
/// sole gating variant) plus each additionalRecorded speaker as
/// "recorded:<name>" (reported-only canaries).
@MainActor
@Suite(
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["DICHO_ASR_AB"] == "1")
)
struct AsrABRun {

    // MARK: - Arms

    /// The three arms `asr_ab_plan.md` §3.2 defines. Constructed fresh (with a
    /// fresh `FileAudioCapture`) for every (arm, repeat) — never reused.
    private enum Arm: String, CaseIterable, Hashable {
        /// Production `SpeechTranscriber` config, driven through the real
        /// `TranscriptionEngine` (§3.2.1).
        case baseline
        /// `DictationTranscriber`, production-parity option set, via the
        /// eval-only `DictationEvalEngine` (§3.2.2).
        case dictation
        /// Arm 2 + `AnalysisContext.contextualStrings` — the optional smoke
        /// rider (§3.2.3): a mechanism check (does `setContext` error? is a
        /// seeded rare word recognized?), NOT real vocabulary evaluation —
        /// the existing fixtures are nearly proper-noun-free, so this arm has
        /// weak measurement power. Real vocab evaluation is deferred to a
        /// future milestone with a dedicated proper-noun fixture.
        case dictationCtx = "dictation-ctx"
    }

    /// Arm-3 smoke-rider payload (§3.2.3) — a small, seeded, documented list;
    /// not a real vocabulary set.
    private static let smokeContextStrings = ["Dicho", "Miguel", "Wispr"]

    private static func makeEngine(for arm: Arm, audioSource: FileAudioCapture) -> any TranscriptionEngineProtocol {
        switch arm {
        case .baseline:
            return TranscriptionEngine(audioSource: audioSource)
        case .dictation:
            return DictationEvalEngine(audioSource: audioSource)
        case .dictationCtx:
            return DictationEvalEngine(audioSource: audioSource, contextualStrings: Self.smokeContextStrings)
        }
    }

    // MARK: - Plan

    @Test func runAsrAB() async throws {
        let environment = ProcessInfo.processInfo.environment
        let ids = environment["DICHO_ASR_AB_FIXTURES"].map {
            $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let repeats = environment["DICHO_ASR_AB_REPEATS"].flatMap(Int.init) ?? 3
        let label = environment["DICHO_ASR_AB_LABEL"] ?? "run"
        let requestedArmNames = environment["DICHO_ASR_AB_ARMS"].map {
            $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        } ?? ["baseline", "dictation"]

        var seenArms: Set<Arm> = []
        var arms: [Arm] = []
        for name in requestedArmNames {
            guard let arm = Arm(rawValue: name) else {
                print("[ASR-AB] unknown arm '\(name)' ignored (valid: \(Arm.allCases.map(\.rawValue).joined(separator: ", ")))")
                continue
            }
            if seenArms.insert(arm).inserted {
                arms.append(arm)
            }
        }
        try #require(!arms.isEmpty, "no valid arms in DICHO_ASR_AB_ARMS")

        let manifests = try EvalPaths.loadManifests(ids: ids)
        try #require(!manifests.isEmpty, "no manifests matched DICHO_ASR_AB_FIXTURES")

        // Loaded once for the whole run (§3.3): the ceiling class is
        // deterministic across repeats, so there's no reason to re-decode
        // baseline.json per fixture/arm/repeat.
        let ceilingItems = Self.loadCeilingItems()

        var records: [AsrABScoring.AsrABFixtureArmRecord] = []
        var skipped: [String] = []

        for manifest in manifests {
            for (variantName, relativePath) in Self.variants(of: manifest) {
                let audioURL = EvalPaths.audioURL(relativePath)
                guard FileManager.default.fileExists(atPath: audioURL.path) else {
                    skipped.append("\(manifest.id)@\(variantName)")
                    continue
                }
                for repeatIndex in 0..<repeats {
                    for arm in arms {
                        let record = await Self.runOnce(
                            manifest: manifest,
                            variant: variantName,
                            audioURL: audioURL,
                            arm: arm,
                            repeatIndex: repeatIndex,
                            ceilingItems: ceilingItems
                        )
                        Self.printRecord(record)
                        Self.printCeilingDetail(record, items: ceilingItems)
                        records.append(record)
                        // Breather between arm runs so the previous arm's
                        // analyzer/session teardown can't bleed into the next
                        // arm's timings (mirrors EvalRun's inter-repeat
                        // breather — same teardown-bleed insurance, applied
                        // here between arms since arms run sequentially
                        // within a repeat).
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
            }
        }

        try #require(!records.isEmpty, "no fixture variant had audio — record fixtures first (RECORDING.md)")

        // Reuses ConfigFingerprint.capture for the timestamp/gitCommit
        // mechanism (date formatting + `git rev-parse --short HEAD`) rather
        // than duplicating it; the cleanup/rescoring-instruction fingerprint
        // fields it also computes aren't meaningful for an ASR-only A/B and
        // are discarded.
        let fingerprint = ConfigFingerprint.capture(label: label, repeats: repeats, audioMode: "recorded")
        let report = AsrABScoring.AsrABReport(
            label: label,
            timestamp: fingerprint.timestamp,
            gitCommit: fingerprint.gitCommit,
            arms: arms.map(\.rawValue),
            records: records,
            skipped: skipped
        )

        let directory = try Self.writeReport(report)
        print("[ASR-AB] report written: \(directory.path)")
    }

    // MARK: - One (arm, repeat) execution

    private static func runOnce(
        manifest: EvalManifest,
        variant: String,
        audioURL: URL,
        arm: Arm,
        repeatIndex: Int,
        ceilingItems: [AsrABScoring.CeilingItem]
    ) async -> AsrABScoring.AsrABFixtureArmRecord {
        let clock = ContinuousClock()

        // Fresh capture + fresh engine per (arm, repeat) — never reused
        // across arms or repeats. Both are kept as local `let`s referenced
        // through the end of this function (the engine holds `capture`
        // `unowned`, mirroring production, so `capture` must outlive it).
        let capture = FileAudioCapture(fileURL: audioURL)
        let engine = Self.makeEngine(for: arm, audioSource: capture)

        let (playbackDone, playbackContinuation) = AsyncStream<Void>.makeStream()
        capture.onPlaybackFinished = { playbackContinuation.finish() }

        do {
            try await engine.start()
        } catch {
            Issue.record("\(manifest.id)@\(variant) \(arm.rawValue) #\(repeatIndex): engine.start() threw \(error)")
            return Self.failureRecord(manifest: manifest, variant: variant, arm: arm, repeatIndex: repeatIndex)
        }

        // Started immediately after engine.start() succeeds so no update
        // (including an early volatile) is missed. Runs on this MainActor
        // context (the suite is @MainActor and Task {} inherits the
        // isolation of its creating context), so appending to `updates` and
        // stamping `lastFinalInstant` from within it races with nothing else
        // touching those locals.
        var updates: [TranscriptUpdate] = []
        var lastFinalInstant: ContinuousClock.Instant?
        let consumerTask = Task {
            for await update in engine.updates {
                updates.append(update)
                if update.isFinal {
                    lastFinalInstant = clock.now
                }
            }
        }

        do {
            try capture.startCapture()
        } catch {
            Issue.record("\(manifest.id)@\(variant) \(arm.rawValue) #\(repeatIndex): capture.startCapture() threw \(error)")
            // The consumer task is already running against engine.updates;
            // finish it cleanly via engine.stop() before bailing so we don't
            // leak the Task or hang the suite.
            await engine.stop()
            await consumerTask.value
            return Self.failureRecord(manifest: manifest, variant: variant, arm: arm, repeatIndex: repeatIndex)
        }

        // Resolves when EOF + trailing silence have been fed — the analog of
        // the user tapping stop right after their last word.
        for await _ in playbackDone {}
        let stopInstant = clock.now

        // FileAudioCapture's feed already finished the analyzer continuation
        // at EOF (see FileAudioCapture.feed: `continuation.finish()` before
        // `onPlaybackFinished` fires), so this call is a defensive no-op —
        // finishing an already-finished continuation is harmless — kept
        // anyway to mirror the production stop order (coordinator calls
        // audioCapture.stopCapture() before transcriptionEngine.stop()).
        capture.stopCapture()
        await engine.stop()

        // engine.stop() finishes the updates continuation once its own
        // drain/finalize work completes; the consumer task then exits.
        await consumerTask.value

        let finals = updates.filter(\.isFinal)
        let rawTopJoin = AsrABScoring.rawTopJoin(of: updates)
        let score = AsrABScoring.score(spoken: manifest.spoken, rawTopJoin: rawTopJoin)
        let ceiling = AsrABScoring.ceilingRecovery(items: ceilingItems, fixtureID: manifest.id, rawTopJoin: rawTopJoin)
        let confidence = AsrABScoring.confidenceStats(of: updates)
        let firings = AsrABScoring.gateFirings(in: finals)

        let stopToLastFinalSeconds: Double = {
            guard let lastFinalInstant else { return 0 }
            return max(0, stopInstant.duration(to: lastFinalInstant).evalSeconds)
        }()

        return AsrABScoring.AsrABFixtureArmRecord(
            fixtureID: manifest.id,
            variant: variant,
            armName: arm.rawValue,
            repeatIndex: repeatIndex,
            rawTopJoin: rawTopJoin,
            contentMajorCount: score.contentMajors.count,
            minorCount: score.minors.count,
            fillerDropCount: score.fillerDrops.count,
            contentMajors: score.contentMajors,
            minors: score.minors,
            fillerDrops: score.fillerDrops,
            ceiling: ceiling,
            confidence: confidence,
            gateFirings: firings,
            segmentCount: finals.count,
            alternativesPerFinal: finals.map { $0.alternatives.count },
            stopToLastFinalSeconds: stopToLastFinalSeconds
        )
    }

    private static func failureRecord(
        manifest: EvalManifest,
        variant: String,
        arm: Arm,
        repeatIndex: Int
    ) -> AsrABScoring.AsrABFixtureArmRecord {
        AsrABScoring.AsrABFixtureArmRecord(
            fixtureID: manifest.id,
            variant: variant,
            armName: arm.rawValue,
            repeatIndex: repeatIndex,
            rawTopJoin: "",
            contentMajorCount: 0,
            minorCount: 0,
            fillerDropCount: 0,
            contentMajors: [],
            minors: [],
            fillerDrops: [],
            ceiling: AsrABScoring.CeilingRecovery(total: 0, recovered: 0, unmatchable: 0),
            confidence: AsrABScoring.ConfidenceStats(count: 0, minimum: nil, median: nil, deciles: Array(repeating: 0, count: 10)),
            gateFirings: 0,
            segmentCount: 0,
            alternativesPerFinal: [],
            stopToLastFinalSeconds: 0
        )
    }

    // MARK: - Ceiling items

    /// Loads the `asr-ceiling` majors from `EvalResults/baseline.json` once,
    /// at run start. Missing/undecodable baseline disables ceiling recovery
    /// for the whole run rather than failing it — the A/B still produces
    /// content-major/minor and confidence numbers without it.
    private static func loadCeilingItems() -> [AsrABScoring.CeilingItem] {
        guard let data = try? Data(contentsOf: EvalPaths.baselineFile),
              let items = try? AsrABScoring.ceilingItems(fromBaselineJSON: data)
        else {
            print("[ASR-AB] no baseline.json — ceiling recovery disabled")
            return []
        }
        return items
    }

    // MARK: - Variants

    /// Human recordings only (TTS retired) — identical to `EvalRun`'s
    /// `variants(of:)`: the developer's voice ("recorded", the sole gating
    /// variant) plus each additionalRecorded speaker as "recorded:<name>"
    /// (reported-only canaries).
    private static func variants(of manifest: EvalManifest) -> [(name: String, path: String)] {
        var list: [(String, String)] = []
        if let recorded = manifest.audio.recorded {
            list.append(("recorded", recorded))
        }
        list += (manifest.audio.additionalRecorded ?? []).map { ("recorded:\($0.name)", $0.file) }
        return list
    }

    // MARK: - Console output

    private static func printRecord(_ record: AsrABScoring.AsrABFixtureArmRecord) {
        let confMin = record.confidence.minimum.map { String(format: "%.2f", $0) } ?? "-"
        print(String(
            format: "[ASR-AB] %@@%@ %@ #%d: majors=%d minors=%d fillers=%d ceil=%d/%d conf.min=%@ gate=%d stop→lastFinal=%.2fs",
            record.fixtureID, record.variant, record.armName, record.repeatIndex,
            record.contentMajorCount, record.minorCount, record.fillerDropCount,
            record.ceiling.recovered, record.ceiling.total,
            confMin, record.gateFirings, record.stopToLastFinalSeconds
        ))
    }

    /// One line per ceiling item belonging to this record's fixture, for
    /// qualitative review (§3.3). `item.expected` is fixture-script content
    /// (the manifest's spoken/expected reference text), not user dictation —
    /// fine to print in an eval-only context.
    private static func printCeilingDetail(
        _ record: AsrABScoring.AsrABFixtureArmRecord,
        items: [AsrABScoring.CeilingItem]
    ) {
        for item in items where item.fixtureID == record.fixtureID {
            let status: String
            switch AsrABScoring.recovered(item, inRawTopJoin: record.rawTopJoin) {
            case .some(true):
                status = "recovered"
            case .some(false):
                status = "missed"
            case .none:
                status = "unmatchable"
            }
            print("[ASR-AB]   ceiling '\(item.expected ?? "<nil>")': \(status)")
        }
    }

    // MARK: - Report writing

    /// `EvalReportWriter.write` is typed to `EvalRunReport` — the M12
    /// pipeline schema `AsrABReport` deliberately does not fit
    /// (`asr_ab_plan.md` §3.3: "do not force the pipeline-shaped
    /// EvalRunReport schema"). So the directory-naming convention
    /// (`<timestamp>-<suffix>`) and the encoder/write mechanics are mirrored
    /// here rather than reused directly.
    private static func writeReport(_ report: AsrABScoring.AsrABReport) throws -> URL {
        let directory = EvalPaths.resultsDirectory
            .appendingPathComponent("\(report.timestamp)-asr-ab-\(report.label)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: directory.appendingPathComponent("run.json"))

        try AsrABScoring.summaryMarkdown(for: report).write(
            to: directory.appendingPathComponent("summary.md"),
            atomically: true,
            encoding: .utf8
        )
        return directory
    }
}
