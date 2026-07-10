import AVFoundation
import FoundationModels
import Speech
import Testing
@testable import Dicho

/// M12 eval harness — 12.1 spike-gate.
///
/// These tests make LIVE Speech and FoundationModels calls, which the unit-test
/// gate forbids. They are structurally excluded from `xcodebuild test` by the
/// `.enabled(if:)` trait: they only run when `DICHO_EVAL=1` is present in the
/// runner environment. xcodebuild forwards `TEST_RUNNER_`-prefixed variables
/// into the hosted runner (the app process), so the eval invocation is:
///
///     TEST_RUNNER_DICHO_EVAL=1 xcodebuild test -scheme Dicho \
///         -destination 'platform=macOS' -only-testing:DichoTests/EvalSpikeTests
///
/// A plain gate run reports the suite as skipped. This trait mechanism is the
/// convention amendment approved with the M12 spec (2026-07-10); see
/// `Documentation/eval_harness_plan.md` §"Harness home".
///
/// What the spike proves (gate for the rest of M12):
/// 1. File-based transcription works in the hosted-test context with the
///    exact production transcriber options — finals carry n-best alternatives
///    and per-run confidence (re-validates the M10 C0 finding in THIS runtime
///    context, via the same stream-feeding approach `FileAudioCapture` will
///    use in 12.3; the real-engine path lands with the 12.2 seam).
/// 2. A live `LanguageModelSession.respond` succeeds in the hosted context.
@MainActor
@Suite(
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["DICHO_EVAL"] == "1")
)
struct EvalSpikeTests {

    // MARK: - 12.1(a) Speech: file-based transcription with alternatives + confidence

    @Test func fileTranscriptionYieldsFinalsWithAlternativesAndConfidence() async throws {
        // Generate fixture audio with `say` (authored test content — the
        // unit-test-fixture exemption in CLAUDE.md's privacy rule).
        let spokenFixture = "We took the bus to the deli on Tuesday, no wait, Thursday afternoon."
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("eval-spike-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", audioURL.path, spokenFixture]
        try say.run()
        say.waitUntilExit()
        try #require(say.terminationStatus == 0, "`say` failed to render the fixture audio")

        // Transcriber configured EXACTLY like production TranscriptionEngine.start().
        let preferredLocale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
        let fallbackLocale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
        let locale = try #require(preferredLocale ?? fallbackLocale)

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .alternativeTranscriptions],
            attributeOptions: [.transcriptionConfidence]
        )
        if let request = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let format = try #require(await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber],
            considering: nil
        ))

        // Throwaway file feeder: whole file → analyzer format → one buffer.
        // (12.3's FileAudioCapture does the same conversion chunked + 1×-paced.)
        let analyzerBuffer = try Self.readAndConvert(audioURL, to: format)

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try? await analyzer.prepareToAnalyze(in: format)

        struct FinalSegment {
            let text: String
            let alternatives: [String]
            let confidence: Double?
        }
        let resultsTask = Task {
            var finals: [FinalSegment] = []
            do {
                for try await result in transcriber.results where result.isFinal {
                    finals.append(FinalSegment(
                        text: String(result.text.characters),
                        alternatives: result.alternatives.map { String($0.characters) },
                        confidence: TranscriptionEngine.minimumConfidence(in: result.text)
                    ))
                }
            } catch {
                Issue.record("transcriber.results threw: \(error)")
            }
            return finals
        }

        continuation.yield(AnalyzerInput(buffer: analyzerBuffer))
        continuation.finish()
        _ = try await analyzer.analyzeSequence(stream)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let finals = await resultsTask.value

        // Spike evidence for the console log.
        print("[EVAL-SPIKE] finals: \(finals.count)")
        for (i, final) in finals.enumerated() {
            let confidence = final.confidence.map { String(format: "%.2f", $0) } ?? "nil"
            print("[EVAL-SPIKE] final \(i): '\(final.text)' confidence=\(confidence) alternatives=\(final.alternatives)")
        }

        // Environment-validation assertions (deliberately lenient — quality is
        // the harness's job, not the spike's).
        #expect(!finals.isEmpty, "no finalized segments — file-based transcription failed")
        #expect(finals.contains { !$0.alternatives.isEmpty }, "no final carried alternatives")
        #expect(finals.contains { $0.confidence != nil }, "no final carried a confidence attribute")
        let joined = finals.map(\.text).joined().lowercased()
        #expect(joined.contains("thursday"), "transcript unexpectedly missing an anchor word: '\(joined)'")
    }

    // MARK: - 12.1(b) FoundationModels: live respond in the hosted context

    @Test func liveFoundationModelsRespondSucceeds() async throws {
        let availability = SystemLanguageModel.default.availability
        guard case .available = availability else {
            Issue.record("FoundationModels unavailable in the hosted eval context: \(String(describing: availability))")
            return
        }

        // Same construction pattern as the production sessions (permissive
        // guardrails; see FoundationModelRescoringSession / M9 rationale).
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        let session = LanguageModelSession(model: model, instructions: "Reply with a single English word.")
        let response = try await session.respond(to: "Say the word hello.")

        print("[EVAL-SPIKE] FM response: '\(response.content)'")
        #expect(!response.content.isEmpty, "live FoundationModels respond returned empty content")
    }

    // MARK: - Helpers

    /// Reads an entire audio file and converts it to the analyzer's format.
    /// Same single-shot AVAudioConverter pattern as `AudioCapture.convert`,
    /// applied to the whole file instead of a tap buffer.
    private static func readAndConvert(_ url: URL, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        let sourceBuffer = try #require(AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ))
        try file.read(into: sourceBuffer)

        if sourceFormat == format { return sourceBuffer }

        let converter = try #require(AVAudioConverter(from: sourceFormat, to: format))
        let capacity = AVAudioFrameCount(
            Double(sourceBuffer.frameLength) * format.sampleRate / sourceFormat.sampleRate
        ) + 1024
        let converted = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity))
        var consumed = false
        var conversionError: NSError?
        converter.convert(to: converted, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return sourceBuffer
        }
        try #require(conversionError == nil, "AVAudioConverter failed: \(String(describing: conversionError))")
        return converted
    }
}
