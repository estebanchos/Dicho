# Autonomous tuning-loop protocol (M12.9)

The agent runs this loop on the milestone branch. It is the operating
contract; `EvalCompare` (DichoTests/Eval/Scoring) encodes the accept/reject
rules deterministically. Full context: `Documentation/eval_harness_plan.md`.

## Preconditions

- Unit suite green (`xcodebuild test`, eval suite skipped).
- Baseline promoted: `EvalResults/baseline.json` (5 repeats, all fixtures,
  both audio variants).
- Targets set by the developer: `EvalFixtures/targets.json`.

## Per iteration

1. **One variable.** A single `Constants` value OR one prompt-rule edit
   (wording, order, or worked example) in ONE prompt — never both prompts in
   the same iteration. Write the hypothesis to
   `EvalResults/EXPERIMENT_LOG.md` BEFORE running.
2. **TDD for prompt changes.** Update the golden-file tests, implement, gate
   suite green.
3. **Run.** 3 repeats, tuning-tagged fixtures, both audio variants:
   ```
   TEST_RUNNER_DICHO_EVAL=1 xcodebuild test -scheme Dicho \
     -destination 'platform=macOS' -only-testing:DichoTests/EvalRun
   ```
4. **Compare** against the current accepted baseline (`EvalCompare`).
   Accept iff ALL of:
   - no fixture gains a worst-run recoverable major vs baseline;
   - recoverable majors strictly decrease, OR equal majors with minors
     decreasing, OR equal quality with total latency down ≥ 10%;
   - no latency bound in targets.json violated;
   - full unit suite green.
5. **On accept:** conventional commit (no co-author trailer), promote the
   run.json to `EvalResults/baseline.json`, log the result.
6. **On reject:** revert the working tree; log the negative result with its
   evidence — negative findings are project currency.

## Stop conditions

- `EvalCompare.targetsMet` true → report success to the developer.
- 5 consecutive rejects → plateau; deliver a residual-error analysis
  (remaining deviations by layer) and stop.
- Developer interrupt.

## Guardrails (from ARCHITECTURE.md's model-constraints section)

- Reports carry instruction char counts; +15% growth from the M12-start
  fingerprint is a warning — prompt growth costs rule-following at 3B scale.
  Shrinking or reordering rules is as legitimate an experiment as adding.
- Worked examples must mirror transcript shapes exactly (the M9 lesson).
- Never weaken the FORBIDDEN block.
- `asr-ceiling` deviations are never chased with prompt changes — log them
  as OPTIMIZATIONS candidates instead.
- Holdout-tagged fixtures never drive accept/reject; a widening
  tuning-vs-holdout gap is an overfitting alarm → stop and report.
- First candidates: OPTIMIZATIONS #12 backlog (mid-sentence lowercase
  split-marker cleanup example; homophone-spelling selector hint;
  ordinal/number-format guard; selector guardrail retry-without-context)
  plus the developer-reported missed-correction and punctuation cases.
