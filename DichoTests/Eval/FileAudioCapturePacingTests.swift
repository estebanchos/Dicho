import Foundation
import Testing
@testable import Dicho

/// Pure pacing-math tests for the eval harness's `FileAudioCapture` (M12.3).
/// These run in the normal gate — no audio I/O, no live calls.
@Suite("EvalPacing")
struct FileAudioCapturePacingTests {

    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
    }

    @Test("Offset after N frames is N over the sample rate")
    func offsetMatchesFrameArithmetic() {
        #expect(seconds(PacingSchedule.offset(afterFrames: 44_100, sampleRate: 44_100)) == 1.0)
        #expect(seconds(PacingSchedule.offset(afterFrames: 22_050, sampleRate: 44_100)) == 0.5)
        #expect(seconds(PacingSchedule.offset(afterFrames: 16_000, sampleRate: 16_000)) == 1.0)
        #expect(seconds(PacingSchedule.offset(afterFrames: 0, sampleRate: 48_000)) == 0.0)
    }

    @Test("Deadlines are total-based, so chunk splits cannot accumulate drift")
    func deadlinesAreDriftFree() {
        // The same total frame count must produce the same deadline regardless
        // of how the preceding chunks were split — the implementation computes
        // offsets from the running total, never by summing per-chunk durations.
        let sampleRate = 22_050.0
        let splitA: [Int64] = [4_096, 4_096, 4_096, 808]
        let splitB: [Int64] = [1_000, 12_096]
        let totalA = splitA.reduce(0, +)
        let totalB = splitB.reduce(0, +)
        #expect(totalA == totalB)
        let offsetA = PacingSchedule.offset(afterFrames: totalA, sampleRate: sampleRate)
        let offsetB = PacingSchedule.offset(afterFrames: totalB, sampleRate: sampleRate)
        #expect(offsetA == offsetB)
        #expect(abs(seconds(offsetA) - Double(totalA) / sampleRate) < 1e-12)
    }

    @Test("Deadlines are monotonically nondecreasing as frames accumulate")
    func deadlinesAreMonotone() {
        let sampleRate = 16_000.0
        var fed: Int64 = 0
        var previous = PacingSchedule.offset(afterFrames: 0, sampleRate: sampleRate)
        for chunk in [4_096, 4_096, 512, 1, 4_096] as [Int64] {
            fed += chunk
            let next = PacingSchedule.offset(afterFrames: fed, sampleRate: sampleRate)
            #expect(next >= previous)
            previous = next
        }
    }

    @Test("Trailing-silence frame count rounds and never goes negative")
    func silenceFrames() {
        #expect(PacingSchedule.silenceFrames(duration: 0.3, sampleRate: 16_000) == 4_800)
        #expect(PacingSchedule.silenceFrames(duration: 0.3, sampleRate: 44_100) == 13_230)
        #expect(PacingSchedule.silenceFrames(duration: 0, sampleRate: 44_100) == 0)
        #expect(PacingSchedule.silenceFrames(duration: -1, sampleRate: 44_100) == 0)
    }
}
