# Recording the eval fixtures (developer, once — M12.7)

Your voice is the primary tuning signal: the accent-driven ASR errors the
rescoring layer exists for do not reproduce on TTS audio. One take per
fixture is enough; total ~15 minutes.

## How

1. Open a manifest and read its `spoken` text — that exact text, including
   every "um", "uh", "no wait", "scratch that": the disfluencies ARE the test.
   Print one cleanly with:
   ```
   plutil -extract spoken raw -o - EvalFixtures/manifests/<id>.json
   ```
2. Speak naturally, at your normal dictation pace and distance from the mic —
   the same way you'd dictate with Dicho day to day. Don't perform; don't
   over-articulate.
3. `[pause:N]` means: silently pause about N seconds, then CONTINUE the
   sentence as if nothing happened (no restart, no breath reset).
4. Record with QuickTime (File → New Audio Recording) or Voice Memos.
   Any of m4a / wav / aiff works.
5. Save each file as `EvalFixtures/audio/recorded/<id>.m4a` (exact fixture id
   as the filename). The directory is gitignored — your voice never enters git.
6. Flubbed a take? Just re-record the file. Nothing else to update.

## The fixtures

| id | ~read time | watch for |
|---|---|---|
| self-corrections-basic | 20 s | say the correction markers naturally |
| self-correction-midsentence | 15 s | "no wait" mid-sentence, no pause around it |
| pause-seams | 25 s | honor the three [pause:2] markers |
| fillers-dense | 20 s | every filler as written |
| near-homophones-esl | 25 s | normal pace — this one hunts your accent's ASR errors |
| numbers-ordinals | 20 s | numbers as words, exactly as written |
| spoken-register | 15 s | "gonna"/"gotta"/"kinda" casually |
| homophone-spelling | 15 s | even pace |
| tech-passthrough | 15 s | "parse JSON" as two words |
| guardrail-profanity | 20 s | natural annoyance, profanity included |
| long-multiphenomenon | ~4 min | one continuous take; markers + pauses as written |

Missing recordings are fine at first: the runner skips absent audio variants
and notes them in the report, so TTS-only runs work before you record.
