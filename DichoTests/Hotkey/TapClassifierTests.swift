import Testing
@testable import Dicho

@Suite("TapClassifier")
struct TapClassifierTests {

    // MARK: - Initial state

    @Test func isActiveDefaultsFalse() {
        let c = TapClassifier()
        #expect(c.isActive == false)
    }

    // MARK: - Happy path: double-tap activates

    @Test func doubleTapWithinThresholdActivates() {
        var c = TapClassifier()
        #expect(c.process(.ctrlDown(at: 0.0)) == nil)
        #expect(c.process(.ctrlUp(at: 0.05)) == nil)
        #expect(c.process(.ctrlDown(at: 0.2)) == nil)   // 0.15s gap < 0.4s threshold
        #expect(c.process(.ctrlUp(at: 0.25)) == .activated)
        #expect(c.isActive == true)
    }

    @Test func doubleTapAtExactThresholdActivates() {
        // "within 400ms" ≡ gap ≤ threshold; boundary should activate
        var c = TapClassifier()
        #expect(c.process(.ctrlDown(at: 0.0)) == nil)
        #expect(c.process(.ctrlUp(at: 0.0)) == nil)      // immediate release
        #expect(c.process(.ctrlDown(at: 0.4)) == nil)    // gap = 0.4 == threshold
        #expect(c.process(.ctrlUp(at: 0.45)) == .activated)
    }

    // MARK: - Slow double-tap does not activate

    @Test func slowDoubleTapRestartsCycle() {
        // Second tap arrives later than threshold; it becomes the new first tap.
        var c = TapClassifier()
        #expect(c.process(.ctrlDown(at: 0.0)) == nil)
        #expect(c.process(.ctrlUp(at: 0.05)) == nil)
        // Gap = 0.5s > 0.4s threshold → second ctrlDown treated as a fresh first tap
        #expect(c.process(.ctrlDown(at: 0.55)) == nil)
        #expect(c.process(.ctrlUp(at: 0.6)) == nil)
        #expect(c.isActive == false)
    }

    // MARK: - Ctrl+C / combo safety

    @Test func ctrlCDuringFirstTapResetsGesture() {
        // ctrlDown → interruptingKey (the 'C') → ctrlUp: should NOT be treated as a valid tap
        var c = TapClassifier()
        #expect(c.process(.ctrlDown(at: 0.0)) == nil)
        #expect(c.process(.interruptingKey) == nil)
        #expect(c.process(.ctrlUp(at: 0.05)) == nil)
        // Now attempt a complete second tap: still won't activate because first tap was dirty
        #expect(c.process(.ctrlDown(at: 0.1)) == nil)
        #expect(c.process(.ctrlUp(at: 0.15)) == nil)
        #expect(c.isActive == false)
    }

    @Test func ctrlCDuringSecondTapPreventsActivation() {
        var c = TapClassifier()
        // Clean first tap
        #expect(c.process(.ctrlDown(at: 0.0)) == nil)
        #expect(c.process(.ctrlUp(at: 0.05)) == nil)
        // Second tap interrupted by another key
        #expect(c.process(.ctrlDown(at: 0.15)) == nil)
        #expect(c.process(.interruptingKey) == nil)
        #expect(c.process(.ctrlUp(at: 0.2)) == nil)
        #expect(c.isActive == false)
    }

    // MARK: - Esc behaviour

    @Test func escapeWhenInactiveProducesNothing() {
        var c = TapClassifier()
        #expect(c.process(.escape) == nil)
        #expect(c.isActive == false)
    }

    @Test func escapeWhileActiveCancels() {
        var c = activate()
        #expect(c.process(.escape) == .cancelled)
        #expect(c.isActive == false)
    }

    @Test func escapeDuringStopPhaseStillCancels() {
        // ctrlDown while active → stopDown phase; Esc should still cancel.
        var c = activate()
        #expect(c.process(.ctrlDown(at: 1.0)) == nil)
        #expect(c.process(.escape) == .cancelled)
        #expect(c.isActive == false)
    }

    // MARK: - Single-tap stop

    @Test func singleCleanTapWhileActiveDeactivates() {
        var c = activate()
        #expect(c.process(.ctrlDown(at: 1.0)) == nil)
        #expect(c.process(.ctrlUp(at: 1.05)) == .deactivated)
        #expect(c.isActive == false)
    }

    @Test func ctrlComboDuringStopPhaseDoesNotDeactivate() {
        // Ctrl+X while active (e.g. cut): should not stop dictation.
        var c = activate()
        #expect(c.process(.ctrlDown(at: 1.0)) == nil)
        #expect(c.process(.interruptingKey) == nil)   // 'X' key pressed while Ctrl held
        #expect(c.process(.ctrlUp(at: 1.1)) == nil)
        #expect(c.isActive == true)                   // still recording
    }

    // MARK: - Triple-tap

    @Test func tripleTapActivatesThenImmediatelyDeactivates() {
        var c = TapClassifier()
        // Taps 1+2: activate
        c.process(.ctrlDown(at: 0.0))
        c.process(.ctrlUp(at: 0.05))
        c.process(.ctrlDown(at: 0.1))
        let g1 = c.process(.ctrlUp(at: 0.15))
        #expect(g1 == .activated)
        // Tap 3: stop
        c.process(.ctrlDown(at: 0.2))
        let g2 = c.process(.ctrlUp(at: 0.25))
        #expect(g2 == .deactivated)
        #expect(c.isActive == false)
    }

    // MARK: - Re-use after deactivation / cancellation

    @Test func canReactivateAfterDeactivation() {
        var c = activate()
        c.process(.ctrlDown(at: 1.0))
        _ = c.process(.ctrlUp(at: 1.05))   // deactivated
        // Fresh double-tap
        c.process(.ctrlDown(at: 2.0))
        c.process(.ctrlUp(at: 2.05))
        c.process(.ctrlDown(at: 2.1))
        let g = c.process(.ctrlUp(at: 2.15))
        #expect(g == .activated)
        #expect(c.isActive == true)
    }

    @Test func canReactivateAfterCancellation() {
        var c = activate()
        _ = c.process(.escape)   // cancelled
        // Fresh double-tap
        c.process(.ctrlDown(at: 1.0))
        c.process(.ctrlUp(at: 1.05))
        c.process(.ctrlDown(at: 1.1))
        let g = c.process(.ctrlUp(at: 1.15))
        #expect(g == .activated)
        #expect(c.isActive == true)
    }

    // MARK: - Helpers

    /// Returns a TapClassifier that has already been activated.
    private func activate() -> TapClassifier {
        var c = TapClassifier()
        c.process(.ctrlDown(at: 0.0))
        c.process(.ctrlUp(at: 0.05))
        c.process(.ctrlDown(at: 0.1))
        _ = c.process(.ctrlUp(at: 0.15))
        return c
    }
}
