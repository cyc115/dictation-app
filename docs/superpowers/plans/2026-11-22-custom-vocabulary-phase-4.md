# Custom vocabulary, phase 4 Implementation Plan

Spec: `docs/superpowers/specs/2026-11-22-custom-vocabulary-design.md` (Phase 4: the judge, Privacy,
Tests, Measuring runs). Executed inline in one session on `cyc_vocabulary_4`, test first,
`./test.sh` green at each commit.

**Goal:** with *Ask a model about my fixes* on, each word change of a fix gets a verdict
(`misheard`, `style`, `changedMind`, `unclear`) from a model, in batches, only when the app is idle.
Only misheard changes go into vocabulary; a captured edit keeps only its misheard and style changes,
and a clear one read back from the text box trains Learn without waiting for Accept. Nothing in a
dictation waits on it.

**Architecture:** no new scheduler and no new shared object. Phase 2's idle pass
(`VocabularyIntake`) gains a judge step; `FixJudge` is pure logic plus two backends.
- `FixJudge` (`Vocabulary/FixJudge.swift`): `pending(entries)` (fixes whose intake has an unjudged
  change and fewer than 3 tries), the message (`message(items, terms)`: stable instructions in
  `JudgeFixes.txt`, a package resource the bench reads too, then the terms, then the numbered
  fixes), `parse(answer, items)` (strict JSON; an item whose verdicts are missing, unknown or the
  wrong count is not covered), and `judged(entry, verdicts)` (what verdicts do to one entry).
- Backends (`FixJudgeBackend`): `OpenRouterJudge` (`OpenRouter.chat`, so it names the app; the
  terms are a cacheable prefix for models that need a breakpoint; 10 fixes a request) and
  `OnDeviceJudge` (Apple Intelligence, one fix a call, as `OnDevicePolish` calls it).
  `FixJudge.backend(settings)` picks: where polish goes (on-device polish: Apple Intelligence if
  available; else OpenRouter with the key and `judgeModel`). Nil: the judge can't run, and the rules
  count as before.
- `VocabularyIntake`: `judgeBackend` (injected; `AppServices.live()` hands in the real one, tests a
  fake; `makeServices` gets none), `send` (where the request runs; tests run it inline), `now`. After
  each pass, `judgeIfDue(tab:)`: setting on, a backend, not busy, no request in flight; due when 5
  fixes wait, the oldest has waited 10 minutes (time first seen pending, in memory), or the tab was
  shown; else a wake-up timer for when the oldest reaches 10 minutes. One batch at a time; its
  answer is applied at once if idle, else held until the next pass. A failed request or an answer
  that covers nothing backs off 10 minutes (a tab shown still sends). After a batch lands the pass
  runs again: the tally recounts with the verdicts, and the next batch goes if still due.
- `CandidateTally.support(in:judging:)`: with the judge active, a change with no verdict waits
  (counts nothing) unless the judge gave up on its fix (3 tries); off, the rules as before. A verdict
  other than misheard never counts.
- `HistoryStore.applyVerdicts`: per entry, only if its target, intake and changes are still what
  was sent; stores the verdicts, or a try. One save.

**What verdicts do** (`FixJudge.judged`):
- A correction (typed, or an accepted capture): verdicts label its changes; it's never rewritten.
- A waiting capture: kept = misheard + style. None kept → dismissed. Else `edited` becomes the
  dictation's text with the non-kept changes reverted (by `WordDiff` hunk, not string replace);
  hunks that aren't changes (punctuation only, words only added or removed) stay as you made them.
  The new intake's `of` is the new target and keeps the verdicts, so it isn't judged again.
- `auto` when: read back, at least one kept change, no `unclear`, no words only added, and the kept
  target isn't empty or the dictation's text. Keystroke captures stay `waiting`.

**Data:** `Intake.tries: Int?` (paid answers that didn't cover the fix; omitted when nil, old files
decode). Settings `judgeFixes` (off) and `judgeModel` (`LearnController.teacherModel`; no row).

## Tasks

1. **FixIntake** (`FixIntakeTests`): `changeHunks` (each change with its hunk), `keeping(_:text:target:)`
   (reverts the changes not kept), `wordsOnlyAdded`.
2. **FixJudge** (`FixJudgeTests`): message, parse (good, fenced, partial, wrong count, unknown
   verdict, garbage), `pending`, `judged` (every verdict effect, the `auto` rule and each exclusion).
3. **History + tally**: `Intake.tries`, `applyVerdicts` (staleness guards, tries), `CandidateTally`
   judging flag; prune of an `auto` capture made by the judge.
4. **Intake wiring** (`VocabularyIntakeTests`-style `FixJudgeTests` with fake backend, fake clock):
   send rules (5 waiting, oldest 10 min with its wake-up, tab shown), never while busy, never with
   the setting off or no backend, batches of 10 / 1, one in flight, held answer applied at the next
   idle, malformed answer and the 3-try limit, failure back-off, no second send after a batch lands,
   usage added up (`UsageMeter`, in memory).
5. **Backends + settings + UI**: `OpenRouterJudge` request (app headers, instructions first, cache
   breakpoint for Anthropic, reasoning fallback), `OnDeviceJudge`, `FixJudge.backend` (on-device vs
   cloud polish setups, no key), `judgeFixes`/`judgeModel`, Settings › Vocabulary row (UI test).
6. **Bench**: `bench/judge_message_fixture.json` (both sides render it identically),
   `bench/edit_cases.json` (~40 written fixes; a Swift test keeps each case's changes equal to
   `FixIntake.changes`), `bench/suites/edits.py` (`run` with models × batch sizes 1 and 10, seeded
   batches, verdict accuracy per change, coverage, cost per request and total; `--dry-run` estimates
   tokens and cost from prices in saved results and sends nothing; `report`, `cases`), registered in
   `suites/__init__.py`; `bench/test_edits.py` with a fake sender.
7. **Live**: `./test.sh --live` judges one batch through `OpenRouterJudge` (not run here).
8. **Docs + gate**: README (feature, Privacy), spec ("Phase 4 as built", the bench-cases deviation),
   `docs/command-line.md`, `bench/README.md`, AGENTS.md's Vocabulary line; `./test.sh`; bench
   pytest; `mike:pre-pr`.
