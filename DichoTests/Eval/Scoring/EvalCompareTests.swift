import Foundation
import Testing
@testable import Dicho

/// M12.4 comparator tests — the accept/reject rules of the autonomous tuning
/// loop, encoded deterministically. Pure logic, run in the normal gate.
@Suite("EvalCompare")
struct EvalCompareTests {

    private func fixture(
        _ id: String,
        majors: Int,
        ceiling: Int = 0,
        minors: Int = 0,
        words: Int = 100,
        latencyMedian: Double = 1.0,
        latencyMax: Double = 1.5,
        isLong: Bool = false
    ) -> FixtureAggregate {
        FixtureAggregate(
            fixtureID: id,
            isLong: isLong,
            worstRunRecoverableMajors: majors,
            ceilingMajors: ceiling,
            minors: minors,
            expectedWordCount: words,
            latencyMedian: latencyMedian,
            latencyMax: latencyMax
        )
    }

    private var defaultTargets: EvalTargets {
        EvalTargets(
            maxRecoverableMajors: 0,
            maxMinorsPer100Words: 1.0,
            latencyShortP50: 2.0,
            latencyShortMax: 3.0,
            latencyLongP50: nil,
            latencyLongMax: nil
        )
    }

    @Test("Fewer recoverable majors is accepted")
    func majorsDecreaseAccepted() {
        let baseline = RunAggregate(fixtures: [fixture("a", majors: 2), fixture("b", majors: 1)])
        let candidate = RunAggregate(fixtures: [fixture("a", majors: 1), fixture("b", majors: 1)])
        let verdict = EvalCompare.compare(baseline: baseline, candidate: candidate, targets: defaultTargets)
        #expect(verdict.accepted)
    }

    @Test("Any fixture gaining a worst-run major vetoes, even if the total drops")
    func perFixtureVetoBeatsTotalImprovement() {
        let baseline = RunAggregate(fixtures: [fixture("a", majors: 3), fixture("b", majors: 0)])
        let candidate = RunAggregate(fixtures: [fixture("a", majors: 0), fixture("b", majors: 1)])
        let verdict = EvalCompare.compare(baseline: baseline, candidate: candidate, targets: defaultTargets)
        #expect(!verdict.accepted)
        #expect(verdict.reasons.contains { $0.contains("b") })
    }

    @Test("Ceiling majors do not veto — they are ASR noise, not the tuner's fault")
    func ceilingMajorsDoNotVeto() {
        let baseline = RunAggregate(fixtures: [fixture("a", majors: 1, ceiling: 0)])
        let candidate = RunAggregate(fixtures: [fixture("a", majors: 0, ceiling: 2)])
        let verdict = EvalCompare.compare(baseline: baseline, candidate: candidate, targets: defaultTargets)
        #expect(verdict.accepted)
    }

    @Test("Equal majors with fewer minors is accepted")
    func minorsDecreaseAccepted() {
        let baseline = RunAggregate(fixtures: [fixture("a", majors: 1, minors: 5)])
        let candidate = RunAggregate(fixtures: [fixture("a", majors: 1, minors: 3)])
        let verdict = EvalCompare.compare(baseline: baseline, candidate: candidate, targets: defaultTargets)
        #expect(verdict.accepted)
    }

    @Test("Equal quality with a >=10 percent latency win is accepted")
    func latencyWinAccepted() {
        let baseline = RunAggregate(fixtures: [fixture("a", majors: 1, minors: 2, latencyMedian: 1.6)])
        let candidate = RunAggregate(fixtures: [fixture("a", majors: 1, minors: 2, latencyMedian: 1.4)])
        let verdict = EvalCompare.compare(baseline: baseline, candidate: candidate, targets: defaultTargets)
        #expect(verdict.accepted)
    }

    @Test("Equal quality with a <10 percent latency win is rejected")
    func smallLatencyWinRejected() {
        let baseline = RunAggregate(fixtures: [fixture("a", majors: 1, minors: 2, latencyMedian: 1.6)])
        let candidate = RunAggregate(fixtures: [fixture("a", majors: 1, minors: 2, latencyMedian: 1.55)])
        let verdict = EvalCompare.compare(baseline: baseline, candidate: candidate, targets: defaultTargets)
        #expect(!verdict.accepted)
        #expect(verdict.reasons.contains { $0.lowercased().contains("no improvement") })
    }

    @Test("A short fixture over the latency bound vetoes an otherwise better run")
    func latencyBoundVetoes() {
        let baseline = RunAggregate(fixtures: [fixture("a", majors: 2)])
        let candidate = RunAggregate(fixtures: [fixture("a", majors: 0, latencyMedian: 2.4)])
        let verdict = EvalCompare.compare(baseline: baseline, candidate: candidate, targets: defaultTargets)
        #expect(!verdict.accepted)
        #expect(verdict.reasons.contains { $0.lowercased().contains("latency") })
    }

    @Test("Long fixtures are exempt from short-fixture latency bounds")
    func longFixturesUseTheirOwnBounds() {
        let baseline = RunAggregate(fixtures: [fixture("long", majors: 2, latencyMedian: 8.0, latencyMax: 9.0, isLong: true)])
        let candidate = RunAggregate(fixtures: [fixture("long", majors: 1, latencyMedian: 8.0, latencyMax: 9.0, isLong: true)])
        let verdict = EvalCompare.compare(baseline: baseline, candidate: candidate, targets: defaultTargets)
        #expect(verdict.accepted)
    }

    @Test("targetsMet requires majors, minors rate, and latency all inside bounds")
    func targetsMetTruthTable() {
        let good = RunAggregate(fixtures: [fixture("a", majors: 0, minors: 1, words: 200)])
        #expect(EvalCompare.targetsMet(good, targets: defaultTargets))

        let tooManyMajors = RunAggregate(fixtures: [fixture("a", majors: 1)])
        #expect(!EvalCompare.targetsMet(tooManyMajors, targets: defaultTargets))

        let tooManyMinors = RunAggregate(fixtures: [fixture("a", majors: 0, minors: 5, words: 100)])
        #expect(!EvalCompare.targetsMet(tooManyMinors, targets: defaultTargets))

        let tooSlow = RunAggregate(fixtures: [fixture("a", majors: 0, latencyMax: 3.5)])
        #expect(!EvalCompare.targetsMet(tooSlow, targets: defaultTargets))
    }

    @Test("Aggregate math: minors per 100 words and recoverable-major totals")
    func aggregateMath() {
        let run = RunAggregate(fixtures: [
            fixture("a", majors: 1, ceiling: 2, minors: 3, words: 150),
            fixture("b", majors: 2, ceiling: 0, minors: 1, words: 50),
        ])
        #expect(run.totalRecoverableMajors == 3)
        #expect(run.totalCeilingMajors == 2)
        #expect(run.totalMinors == 4)
        #expect(run.minorsPer100Words == 2.0)
    }
}
