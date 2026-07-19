import Foundation
import Speech
import Testing
@testable import Dicho

/// Pure mapping logic for M10 rescoring plumbing: `TranscriptUpdate` carries
/// n-best alternatives + segment confidence, and `TranscriptionEngine` exposes
/// a pure helper extracting the minimum per-run confidence from an attributed
/// transcription result. No live Speech calls — attributed strings are built
/// by hand with the `SpeechAttributes.ConfidenceAttribute` key.
@MainActor
@Suite("Transcription mapping — alternatives + confidence plumbing (M10)")
struct TranscriptionMappingTests {

    private typealias ConfidenceKey = AttributeScopes.SpeechAttributes.ConfidenceAttribute

    private func piece(_ text: String, confidence: Double?) -> AttributedString {
        var container = AttributeContainer()
        if let confidence {
            container[ConfidenceKey.self] = confidence
        }
        return AttributedString(text, attributes: container)
    }

    @Test("TranscriptUpdate defaults: legacy call sites get empty alternatives and nil confidence")
    func transcriptUpdateDefaultsKeepLegacyShape() {
        let update = TranscriptUpdate(text: "hello", range: nil, isFinal: true)
        #expect(update.alternatives.isEmpty)
        #expect(update.confidence == nil)
    }

    @Test("TranscriptUpdate carries alternatives and confidence when provided")
    func transcriptUpdateCarriesNewFields() {
        let update = TranscriptUpdate(
            text: " today.",
            range: nil,
            isFinal: true,
            alternatives: [" today.", " today,", " day."],
            confidence: 0.76
        )
        #expect(update.alternatives.count == 3)
        #expect(update.confidence == 0.76)
    }

    @Test("minimumConfidence returns the lowest per-run value — one uncertain word gates the segment")
    func minimumConfidenceAcrossRuns() {
        var text = piece("used ", confidence: 0.94)
        text += piece("to take ", confidence: 1.0)
        text += piece("the boss", confidence: 0.71)
        #expect(TranscriptionEngine.minimumConfidence(in: text) == 0.71)
    }

    @Test("minimumConfidence is nil when no run carries the attribute")
    func minimumConfidenceNilWhenAbsent() {
        let text = AttributedString("plain text with no speech attributes")
        #expect(TranscriptionEngine.minimumConfidence(in: text) == nil)
    }

    @Test("minimumConfidence skips attribute-less runs but honors attributed ones")
    func minimumConfidenceMixedRuns() {
        var text = piece("she made me ", confidence: nil)
        text += piece("who I am", confidence: 0.88)
        #expect(TranscriptionEngine.minimumConfidence(in: text) == 0.88)
    }
}
