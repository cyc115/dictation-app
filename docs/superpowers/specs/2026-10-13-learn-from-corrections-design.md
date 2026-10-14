# Learn from corrections: tune the polish prompt from what you fixed

Prototype (animation and three palettes): https://claude.ai/artifact/65MeKSNP9JUkytbWo2hkVB

## Goal

Step 2 of Corrections. Each correction is a triple: the speech model's raw text (`raw`), what the
app wrote with the current prompt (`text`), and what you wanted (`correction`). One click in the
Corrections tab turns those into the next version of the polish prompt, and shows a number that
proves it helped: your score goes from, say, 65 to 74 while a general test set holds at 70.

The number has to be honest, or the feature is a demo. So the score is cross-validated, and a fixed
general test set guards against a prompt that learned your corrections and forgot everything else.

## What you see

**Corrections tab**, a "Learn" tile above the cards:

- Two scores on a raised panel, each a ring and a figure: **Your corrections** (e.g. 65%) with the
  setup's title under it, and **General test set · guard** (e.g. 70%). Before the first tune the
  rings show the current prompt's scores once they're known (nil until the first run; the tile then
  shows "—").
- A **Learn** button. Below 10 corrections it's greyed out behind "Correct 10 dictations to start
  learning · 7 of 10" with a progress bar. With nothing new since the last tune it reads "Learned"
  and is greyed out.
- Pressing Learn runs one tune, in phases, each visible (timings follow the real work, not fixed):
  1. *Reading your 15 corrections* — a soft wash sweeps down the cards once.
  2. *Trying 3 prompts on Cloud Flash · fold 2 of 5* — three candidate rows (A rules, B examples,
     C both) with a thin bar that fills a fifth per fold and a score that settles. At the end the
     losers fade to 35%, the winner's bar turns green with a "best" tag.
  3. *Checking it on the general test set.*
  4. *What changed* — only the changed hunks of the prompt, removed lines struck through in red,
     added lines on green, both settling to plain after a second.
  5. The left ring turns green and counts up (65 → 74) with a "+9" pill; the right ring shows a
     "held" pill (or the drop). Each card gets "v4 38% off → v5 9% off" and a "learned" tag when it
     is now within 15%.
  6. A result row: "Prompt v5 · learned from 15 corrections · Oct 13 · 412 tokens", **Discard** and
     **Keep v5**. Keep is enabled only when the verdict passes (below).
- Errors (no key, network, teacher refused) show in the status line; nothing is saved.

**Settings → Output**: a "Polish prompt" row under the AI polish toggle (greyed while AI polish is
off, or while nothing has been learned for the setup): a picker of the setup's prompt versions (the
built-in one and every kept learned version, newest last, "v5 · 74% · from v4 · Oct 13"). Choosing
an older one is the revert.

**History / Corrections cards**: a dictation polished with a learned prompt records it like any
other ("Cloud Flash · prompt v5").

## Palette and motion

The app palette. At rest everything is graphite and the system greys. While learning, the button
and candidate bars carry a moving blue → purple → orange gradient (the Insights bar's three
colours). Orange stays what it is in Corrections: the words you changed. Green appears only for
"better": the winner, the delta, the "learned" tags. Motion uses SwiftUI animations with the
default spring; `accessibilityReduceMotion` turns the sweep and the counting off.

## The learning loop

Teacher and student. The *student* is the setup's own polish model with the candidate prompt (what
the app will actually run). The *teacher* writes prompts: Claude Sonnet 5.5 with reasoning on
(medium), the pick of the Oct 14 teacher bake-off (bench/results/polish/README.md). Corrections'
suggestions use GPT-6.1 Sol Pro; the teacher doesn't, because pro mode costs several times the
reasoning tokens for the same list price and writing a prompt under fixed constraints doesn't need it.

**Inputs**: the corrections of the chosen setup's kind (all corrections, whichever setup made them;
the setup is what's being tuned), the setup's current prompt text, its polish model and `wrap`, the
general test set.

**Score** of a prompt on a set of cases: `100 × (1 − mean error)`, where error is the token edit
distance between the student's output and the wanted text over the wanted text's tokens, the same
`error_rate` as `bench/harness.py` (a parity fixture keeps them equal). Continuous, so every
correction moves it. Each case is polished twice and the errors averaged (temperature 0 still
jitters).

**K-fold cross-validation** (K = 5, or the number of corrections when fewer than 5 are unlearned):
the corrections are shuffled with a fixed seed and split into K folds. For each fold, for each of
three *lenses*, the teacher sees the current prompt and the training folds' corrections (raw,
what the current prompt wrote, wanted) and writes a candidate; the student scores it on the
held-out fold only. The teacher never sees a correction it is scored on. After K folds every
correction has one held-out error per lens; the lens with the best score wins.

Lenses: A *rules*: tighten or add cleanup rules, keep the examples. B *examples*: replace the
examples with ones drawn from the corrections, keep the rules. C *both*, and keep the prompt under
400 words. The teacher's answer is the whole prompt in `<prompt>` tags; anything else fails the
candidate for that fold (its cases score as the current prompt's).

**Baseline**: the current prompt is scored the same way on every correction (this is "65", and each
card's "v4 38% off"). It's re-run, not read from `text`, so both sides use today's model.

**Final prompt**: the winning lens, with the teacher given all of the corrections it may learn
from. Its score on your corrections is the lens's cross-validated score, not a score on the training
data.

**Guard**: the student runs the general test set (`polish_cases.json` and `polish_cases_holdout.json`,
68 cases, the bench pass rule: every `must` present, every `must_not` absent, words within 25%) with
the current prompt and the final one. Pass rate before and after.

**Verdict** (Keep enabled): your score up by at least 1 point, and the general pass rate down by at
most 2 points. Otherwise the result row says why ("General set dropped 70 → 64") and only Discard
is offered.

**Incremental**: a correction is *learned* when the active learned prompt's held-out error for it is
≤ 15%. The next tune's teacher sees only the corrections that are new or still failing; all of
them are still scored, so the score is comparable across versions. Learn is enabled at 10
corrections with at least one unlearned; "Learned" otherwise.

**Budget**: 5 folds × 3 lenses + 1 final = 16 teacher calls (well under a dollar; a Sol Pro teacher ran $0.50–1); corrections × (3 lenses + 1
baseline) × 2 repeats + 2 × 68 general ≈ 260 student calls (~$0.02 with Cloud Flash's model).
Student calls run 6 at a time; teacher calls 3 at a time. About a minute.

## Data

`~/Library/Application Support/DictationApp/learned-prompts.json` (`LearnedPromptStore`, file
URL injected for tests):

```json
{"active": {"cloud-flash": "v5"},
 "prompts": [{"version": "v5", "setup": "cloud-flash", "basedOn": "v4", "date": "…",
              "text": "…", "lens": "both", "corrections": 15, "tokens": 412,
              "score": {"mine": 74.2, "mineBefore": 65.1, "general": 70.6, "generalBefore": 70.6},
              "errors": {"<entry id>": 0.09, "…": 0.24},
              "errorsBefore": {"<entry id>": 0.38}}]}
```

- Versions number on from the built-in ones, across setups (`v5`, `v6`, …), so a version name is
  unique and `HistoryEntry.prompt` stays a plain version. Each learned prompt belongs to one setup.
- `PolishPrompt.text(for:)` resolves learned versions through the store, after the built-in ones.
- `AppSettings` applies the active learned version to its setups list (`DictationSetup.prompt`
  becomes a `var`; the setups in the Model picker are the built-in and custom ones with the active
  learned prompt applied), so dictation, Corrections suggestions and the recorded `prompt` all use
  it without further plumbing. The store's changes reload the setups.
- The prompt text is also written to `prompts/<version>.txt` beside the JSON, so
  `bench/suite.py polish run --prompt-file` can benchmark it; bench's `prompt_text` also reads
  learned versions from the JSON.
- The general test set ships inside the app as a package resource (the bench files, linked or
  copied; a bench test checks they're identical).

## Components

- `PolishScore` (new): `tokens`, `editDistance`, `errorRate`, `contains`, `check` ports of
  `bench/harness.py` / `suites/polish.py`; `GeneralCase` decoding of the bench JSON.
- `PromptTuner` (new): the loop above as one `async` function from inputs to a `LearnedPrompt`,
  reporting `TunePhase` values through a callback. The student is a `(instructions) ->
  PolishBackend` factory and the teacher a `(system, user) async throws -> String`, so tests run it
  with fakes and assert the teacher never sees a held-out correction.
- `OpenRouterPolish` gains an optional `reasoning` override (the teacher needs it on).
- `LearnedPromptStore` (new): load/save, `active(for setup)`, `keep(_:)`, `activate(version, for
  setup)`, `isLearned(entry id)`, `nextVersion`.
- `LearnController` (new, main actor, `ObservableObject`): phase, result, Keep/Discard, gate text;
  owns one run at a time.
- `LearnView` (new, in `Learn.swift`): the tile. `CorrectionCard` gets the fit chip. `SettingsView`
  gets the prompt row. `CorrectionsView` hosts `LearnView` and passes the sweep trigger.
- `PromptDiff` (new): line diff of two prompts into hunks with one line of context.

## Tests

- `ScoreTests`: parity fixture `bench/score_fixture.json` (reference, hypothesis, error, and
  must/must_not checks) asserted from Swift and from `bench/test_polish.py`.
- `PromptTunerTests` with a fake teacher and a scripted student: every held-out correction is absent
  from the teacher's input for its fold; the lens scores and the winner; the baseline; the general
  guard and the verdict both ways; learned corrections are scored but not shown to the teacher; a
  teacher answer without `<prompt>` tags fails that candidate without failing the run; a student
  error fails the run with its message.
- `LearnedPromptStoreTests`: round trip; `AppSettings` applies the active version to the setups
  and the picker; `PolishPrompt.text(for: "v5")`; the recorded `prompt` of a dictation; revert.
- UI tests: gate at 7 of 10; a run with fakes shows the candidates, the diff, the scores and the
  result; Keep activates and updates the setup; Discard leaves nothing; the fit chip and "learned"
  tag on cards; the Settings prompt picker.
- Snapshots: `learn-ready`, `learn-done`.
- Performance: `errorRate` on a 2,000-token pair and `PromptDiff` of two 60-line prompts.
- Live (`./test.sh --live`): one teacher call returns a prompt in tags; two general cases scored
  with the student through `PromptTuner`'s real code path.
- bench: `test_polish.py` parity for the score fixture and the resource copy of the cases;
  `prompt_text` reads a learned version.

## Not in this step

- Tuning the on-device prompt with Apple's model as student (slow: ~1 s a case, 260 calls). The
  tile explains it's for cloud setups for now.
- Learning across setups (a Cloud Big prompt from Cloud Flash's tune).
- A bench `polish tune` command; the app is the implementation, bench benchmarks what it wrote.
