import Foundation

/// M12 eval-harness comparator: the autonomous tuning loop's accept/reject
/// rules, encoded deterministically so iteration decisions never depend on
/// agent judgment. Pure logic, Codable for reports, unit-tested in the gate.

/// Numeric targets the developer sets after reviewing the baseline (12.8).
/// Stored in `EvalFixtures/targets.json`. Nil fields are unset bounds.
struct EvalTargets: Codable, Equatable {
    var maxRecoverableMajors: Int?
    var maxMinorsPer100Words: Double?
    var latencyShortP50: Double?
    var latencyShortMax: Double?
    var latencyLongP50: Double?
    var latencyLongMax: Double?
}

/// Per-fixture rollup across a run's repeats. Majors gate on the WORST
/// repeat; latency uses the median and max across repeats. Ceiling majors
/// (truth absent from all candidates) are tracked separately — they are ASR
/// noise no downstream tuning can fix, so they never gate.
struct FixtureAggregate: Codable, Equatable {
    let fixtureID: String
    let isLong: Bool
    let worstRunRecoverableMajors: Int
    let ceilingMajors: Int
    let minors: Int
    let expectedWordCount: Int
    let latencyMedian: Double
    let latencyMax: Double
}

struct RunAggregate: Codable, Equatable {
    let fixtures: [FixtureAggregate]

    var totalRecoverableMajors: Int { fixtures.reduce(0) { $0 + $1.worstRunRecoverableMajors } }
    var totalCeilingMajors: Int { fixtures.reduce(0) { $0 + $1.ceilingMajors } }
    var totalMinors: Int { fixtures.reduce(0) { $0 + $1.minors } }
    var totalWords: Int { fixtures.reduce(0) { $0 + $1.expectedWordCount } }
    var minorsPer100Words: Double {
        totalWords == 0 ? 0 : Double(totalMinors) * 100 / Double(totalWords)
    }
    /// Sum of per-fixture latency medians — the loop's coarse latency metric.
    var latencyMedianSum: Double { fixtures.reduce(0) { $0 + $1.latencyMedian } }
}

struct EvalVerdict: Equatable {
    let accepted: Bool
    let reasons: [String]
}

enum EvalCompare {

    /// Accept iff: no fixture gained a worst-run recoverable major vs its
    /// baseline; no latency bound is violated; and the run improves —
    /// recoverable majors strictly down, OR equal majors with minors down,
    /// OR equal quality with total latency down ≥ 10%.
    static func compare(baseline: RunAggregate, candidate: RunAggregate, targets: EvalTargets) -> EvalVerdict {
        var reasons: [String] = []

        for candidateFixture in candidate.fixtures {
            guard let baselineFixture = baseline.fixtures.first(where: { $0.fixtureID == candidateFixture.fixtureID })
            else { continue }
            if candidateFixture.worstRunRecoverableMajors > baselineFixture.worstRunRecoverableMajors {
                reasons.append(
                    "fixture \(candidateFixture.fixtureID) gained worst-run recoverable majors "
                    + "(\(baselineFixture.worstRunRecoverableMajors) -> \(candidateFixture.worstRunRecoverableMajors))"
                )
            }
        }

        reasons += latencyViolations(candidate, targets: targets)

        let improved: Bool
        if candidate.totalRecoverableMajors < baseline.totalRecoverableMajors {
            improved = true
        } else if candidate.totalRecoverableMajors == baseline.totalRecoverableMajors {
            if candidate.totalMinors < baseline.totalMinors {
                improved = true
            } else if candidate.totalMinors == baseline.totalMinors {
                improved = candidate.latencyMedianSum <= baseline.latencyMedianSum * 0.9
            } else {
                improved = false
            }
        } else {
            improved = false
        }
        if !improved {
            reasons.append("no improvement over baseline (majors/minors/latency all flat or worse)")
        }

        return EvalVerdict(accepted: reasons.isEmpty, reasons: reasons)
    }

    /// The loop's stop condition: every set target bound holds.
    static func targetsMet(_ run: RunAggregate, targets: EvalTargets) -> Bool {
        if let bound = targets.maxRecoverableMajors, run.totalRecoverableMajors > bound { return false }
        if let bound = targets.maxMinorsPer100Words, run.minorsPer100Words > bound { return false }
        return latencyViolations(run, targets: targets).isEmpty
    }

    private static func latencyViolations(_ run: RunAggregate, targets: EvalTargets) -> [String] {
        var violations: [String] = []
        for fixture in run.fixtures {
            let p50Bound = fixture.isLong ? targets.latencyLongP50 : targets.latencyShortP50
            let maxBound = fixture.isLong ? targets.latencyLongMax : targets.latencyShortMax
            if let p50Bound, fixture.latencyMedian > p50Bound {
                violations.append("latency: fixture \(fixture.fixtureID) median \(fixture.latencyMedian)s > \(p50Bound)s")
            }
            if let maxBound, fixture.latencyMax > maxBound {
                violations.append("latency: fixture \(fixture.fixtureID) max \(fixture.latencyMax)s > \(maxBound)s")
            }
        }
        return violations
    }
}
