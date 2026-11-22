# Custom vocabulary, and learning it from your edits

## Goal

Words the app keeps getting wrong (names, products, jargon) get fixed once and stay fixed.

- A **Vocabulary** page to add and manage terms.
- The app **watches how you edit a dictation right after it's pasted** and learns from it.
- Manual corrections, captured edits and vocabulary feed **one pipeline**, which also trains the
  polish prompt (Learn).

Hard constraint: **nothing here adds to the wait between stop and pasted text** except a local
string replacement. Every model call in this spec runs when the app is idle.

## One pipeline

```
manual fix (History pencil) ─┐
captured fix (edit watcher) ─┴─► the dictation's fix ─► word changes ─► judge (idle, batched)
                                                           │
                        misheard changes ──────────────────┼─► vocabulary (after 3 dictations)
                        misheard + style changes ──────────┴─► tuning set (Learn)
                        changed-your-mind changes ────────────► dropped

vocabulary ─► live dictation (replacement, speech hint, terms appended to the polish prompt)
           └► Learn (the student runs the same pipeline)
```

## Phases

Each phase ships on its own, in this order. The riskiest part (the watcher) comes after everything
downstream of it has been proven on manual corrections.

| Phase | Ships | Model calls |
|---|---|---|
| 1 | Vocabulary store, page, Settings section, command line; applied to dictations; Learn runs with it | none new |
| 2 | Intake: word changes from manual corrections, candidates, the 3-dictation auto-add, backfill | none |
| 3 | Edit watcher: captured fixes, waiting for Accept in Corrections | none |
| 4 | Judge: per-change verdicts, batched when idle; high-confidence captured fixes train unreviewed | when idle |

## Phase 1: vocabulary

### Data

`vocabulary.json` in Application Support (`AppPaths.file`), read and written by `VocabularyStore`
(an `ObservableObject` made once in `AppServices.live()`).

```swift
struct VocabularyEntry: Codable, Identifiable {
    var id = UUID()
    var term: String          // how it's written: "GeForce Now"
    var heardAs: [String]     // what the recognizer writes instead: ["G Four Snow", "g force now"]
    var enabled = true
    var source: Source        // .manual, .learned
    var added: Date
    var uses = 0              // times a replacement fired
}
```

The file also holds `candidates` (phase 2). The store reloads the file when its modification date
changed, checked at the start of each dictation and when the page is shown, so a command-line
change reaches the running app.

### Where it applies

| Stage | What vocabulary does | Added wait |
|---|---|---|
| On-device speech (Qwen, Apple) | Terms as `SpeechContext` words, max 50. Setting `vocabularySpeechHint`, **off until measured** | to measure |
| Cloud speech | Nothing: OpenRouter's transcription endpoint takes no prompt | none |
| After transcription, every setup | Each `heardAs` is replaced with its term | microseconds |
| Polish, when on | A terms block is appended to the instructions at run time, max 100 terms | to measure |
| After polish | Replacement again | microseconds |

- **Replacement** (`Vocabulary.apply`): enabled entries, longest variant first. Latin variants match
  case-insensitively at word boundaries; variants with Chinese characters match literally. A match
  is skipped where the term already stands (variant "Claude", term "Claude Code").
  It runs before and after polish because variants are learned from polished text: in the 28
  corrections on Mike's Mac, 128 of 141 short word swaps (91%) have the wrong words in the raw
  transcript too; the second pass catches the rest.
- **`raw` in History stays what the speech model heard**, before replacement, so replaying an old
  dictation (Learn) applies today's vocabulary.
- **Terms block** (`Vocabulary.promptBlock`), most used first, then newest:
  ```
  Vocabulary (write these exactly; the recognizer may mishear them):
  GeForce Now (heard as: G Four Snow, g force now)
  reMarkable
  ```
  With no enabled terms nothing is appended, so the request is identical to today's.
- **Live path, in `DictationController.deliver`:** replace the transcript first, polish that, then
  replace the result. Because the first replacement happens before `polishReporting`, a polish
  that fails, comes back empty or runs out of time still pastes replaced text.
- **Instructions:** one helper gives a setup's `promptText` + block. Every backend built from a
  setup uses it: main, backup (`polishBackup`), on-device, `CorrectionSuggester`, Learn's student.
  `PolishPrompt` versions and `promptText` are never edited (they must match `bench/polish_prompts/`).
- A test checks that with no enabled terms the request and the pasted text are identical to today's.
- **With polish off**, only known `heardAs` variants get fixed.
- `uses` is saved after the paste, never before it.

### Learn runs with vocabulary

- The vocabulary goes into the **`Student` closure** in `LearnController.appTuner`, never into the
  `prompt` handed to `tune`: the teacher would copy the list into the kept prompt. Each case's
  input is the replaced transcript; the student's instructions get the block; its output is
  replaced by a small wrapping `PolishBackend` that forwards `prepare()` and `name` (the protocol's
  defaults would lose the prewarm and rename the model in History; a test checks both).
- One vocabulary snapshot per tune, so an auto-add mid-run can't shift the baseline against the
  candidates. The general set runs with it too.
- `PromptMeasurement` gains a vocabulary fingerprint (hash of the enabled entries); a stored
  measurement with another fingerprint is stale and re-measured.
- A tune takes **at most 60 fixes**: manual and accepted first, newest first, then unreviewed
  captured ones (phase 4). A tune makes 10 teacher calls (3 folds × 3 lenses, then the final
  prompt) that each carry about two thirds of the unlearned fixes, and about 8 student calls per fix.
- **Teacher wording** changes in its own commit, after phase 1 lands. `teacherSystem` says a
  repeatedly misheard term "may be listed by name", which now competes with vocabulary; that
  sentence becomes "terms are handled by a vocabulary list; don't list terms". No paid before and
  after tune (Mike, Nov 22): one pair can't resolve a difference inside the tuner's ±1.5 noise, and
  every real tune is already gated by its cross-validated score, the general set and Keep. A unit
  test checks the wording; the next real Learn is checked by eye for a prompt with no term list.
- v7's baked-in terms stay in v7. Phase 2's backfill brings them into vocabulary from the
  corrections they were learned from.

### What you see

- **Vocabulary tab** in the sidebar (`MainTab.vocabulary`, searchable from the toolbar):
  - an add row: term, and optional "heard as" (comma-separated);
  - **Seen in your edits** (phase 2): candidates with "2 of 3", **Add now**, dismiss;
  - **Your terms**: term, variants as chips, "you added" or "learned Nov 18", "used 9 times", an
    on/off switch, delete. Click a term or chip to edit it;
  - a footer link to `vocabulary.json`.
- **Settings › Vocabulary**: *Use vocabulary* (`vocabularyEnabled`, on), *Hint the on-device speech
  model* (`vocabularySpeechHint`, off), *Learn from my edits* (`learnFromEdits`, off; phase 3),
  *Ask a model about my fixes* (`judgeFixes`, off; phase 4), and **Manage Vocabulary…**.
- **Command line:** `DictationApp vocabulary list [--json]`, `add <term> [--heard a,b]`,
  `remove <term>`. Documented in `docs/command-line.md`.

## Phase 2: intake

`FixIntake` turns a fix into word changes, locally.

- **A fix** is a dictation's `text` and what it should have been: `correction` (manual) or a
  captured edit (phase 3).
- **Word changes:** `WordDiff` words (a Chinese character each, else a run of non-space
  characters), diffed; each replaced run is a change `(old, new)`. Pure insertions and deletions
  are not changes.
- Stored on the History entry as `intake: Intake?` (`of`: the target it was computed from;
  `changes`, each with an optional `verdict`). Recomputed at idle when the target differs from
  `of`, so typing a correction never triggers it.
- **The idle pass** runs 30 s after the app was last busy (`!isBusy`), and when Vocabulary or
  Corrections is opened. Phase 4's judge uses the same pass.
- **Candidates** (in `vocabulary.json`): one per **term** (the new side, case-folded), with each
  `heard` variant and the ids of the dictations it was seen in, and `dismissed`. Counting is by
  term because the same term is misheard differently each time ("Cloud", "Coloule" → Claude).
  - A change counts when its verdict is *misheard* (phase 4), or, with `judgeFixes` off, when both
    sides are at most 4 words and `heard` isn't an ordinary word (below).
  - A term seen in **3 different dictations** (`vocabularyLearnAfter`, no Settings row) becomes a
    learned entry. **Add now** does it at once. A dismissed term never comes back.
  - **Ordinary-word guard:** a `heard` that also stands in 3 or more dictations you didn't correct
    is an ordinary word ("two", "cloud"). It never becomes a `heardAs` variant: replacing it
    everywhere would break the dictations where you meant it. The term is still learned, without
    that variant, so polish and the speech hint can pick it by context.
  - The page lists candidates seen twice or more, or judged *misheard*; the rest sit behind
    "Show all".
- **Backfill:** the first idle pass covers every existing correction. On Mike's Mac today (28
  corrections, 91 distinct short swaps) that gives candidates but no term at 3: 25 of the 91 fail
  the ordinary-word guard, and the only swaps seen twice are "two → 2" and "three → 3". Rules alone
  learn slowly; the judge (phase 4) is what tells a misheard term from a style change.

## Phase 3: the edit watcher

`EditWatcher`, armed by `DictationController` after a text paste, with the app, the text box
(`TextSpot`), the string actually pasted (`inject` returns it, leading space included) and the
History entry's id. Every step that touches the Mac is a closure, as in `GoBack`, so tests run it
with fakes.

- **Never armed:** `learnFromEdits` off; an excluded app; a secure text field; secure input on; a
  command; dictate-and-send; text taken back by *Paste where you dictated*.
- **Ends on:** focus or app change, Return, a new dictation, 30 s without a key, 2 minutes, secure
  input turning on (the watch is dropped).
- **Readback mode.** After the paste the box is read (`AXValue`, `AXSelectedTextRange`). If the
  pasted string is where the cursor says it is, this box supports readback. It's read again when
  typing pauses (0.7 s after the last key) and once before a Return is passed on (only if keys were
  pressed since the last read, capped at 50 ms). The pasted span is found by the text before and
  after it; text typed after the span is not part of the edit.
- **Keystroke mode**, when the probe fails. `TypedEdit` keeps the pasted text and a cursor in
  memory and applies printable keys, Backspace, Delete, ←/→, ⌥←/⌥→, ⌥⌫ and ⇧-selections. It gives
  up, keeping nothing, on a mouse click, an input method (not a keyboard layout) being active, or
  any other shortcut.
- **Keys** come from `HotkeyManager`'s existing global key-down monitor and event tap (a new
  `onKey`); no second tap. With no watch armed the key path does one nil check.
- **Result:** `capture` on the History entry: `edited` (the span as you left it), `mode`, `app`,
  and `state`. An edit with no word changes (appended text, everything deleted, nothing changed)
  leaves no capture.
- **Never written to disk:** keystrokes, or any of the text box beyond the span.

### Captured fixes in History

| `capture.state` | Meaning | Trains Learn | Kept past "Keep history" |
|---|---|---|---|
| `waiting` | Needs your Accept | no | no |
| `auto` | High confidence, unreviewed (phase 4) | yes | no |
| `accepted` | You accepted it | yes | yes |
| `dismissed` | You dismissed it | no | no |

- "Trains Learn" means `correction` is set, so `history.corrections`, Learn and the bench's
  `--corrections` need no change. `prune` keeps a correction forever unless its capture is `auto`.
- Typing a correction on a captured entry makes it yours: `accepted`. Dismissing an `auto` fix
  clears its correction.
- **Corrections tab:** a *Waiting for you* group with Accept and Dismiss, a "captured" badge on
  cards, and the Learn tile says "28 yours · 12 captured" (captured: `accepted` and `auto`).
- In phase 3 every capture is `waiting`.
- **Diagnostics:** per app, watches armed, readback probes failed, keystroke give-ups.

## Phase 4: the judge

`FixJudge` gives each word change a verdict: *misheard*, *style*, *changed mind*, *unclear*.

- **Off the hot path.** Unjudged fixes wait. A batch is sent only when the app has been idle for
  30 s (`!isBusy`) and 5 fixes wait, or the oldest has waited 10 minutes, or Vocabulary or
  Corrections is opened. Nothing in a dictation waits on it.
- **Batched:** up to 10 fixes a request. Each fix is a numbered item (what the app wrote, the
  target, its changes) with the current terms; the answer is strict JSON, a verdict per change.
- **Model:** `judgeModel`, default `LearnController.teacherModel` (Claude Sonnet 5.5) until the
  bench picks one. Through `OpenRouter.chat`, so it names the app like every other call.
- **On-device setup:** Apple Intelligence, one fix a call. If it scores poorly on the suite, the
  On-device setup uses phase 2's rule instead.
- **What verdicts do:**
  - *misheard* changes count toward candidates;
  - a captured fix's target becomes `text` with only its *misheard* and *style* changes applied;
  - none kept: the capture is dismissed;
  - **readback + at least one kept change + no *unclear*: `auto`** (trains without review).
    Keystroke-mode captures always wait for Accept. (Mike was asked whether every capture should
    wait instead and didn't choose; this is the recommended default. Removing this rule makes
    every capture wait.)
- **Bench:** `bench/edit_cases.json` (about 40 labelled fixes: Mike's corrections plus written
  changed-mind cases) and `bench/suite.py edits run`, comparing models and batch sizes 1 and 10.
  Batching stays only if accuracy matches one at a time; then the cheapest model that ties the
  best is the default.

## Privacy

- Vocabulary stays on the Mac. Its terms go where polish already goes (OpenRouter on cloud setups,
  Apple Intelligence on-device).
- The watcher keeps only the pasted text and its edited version, and only with *Learn from my
  edits* on. It doesn't run in excluded apps or password fields.
- The judge sends each fix (what the app wrote, what you changed it to) to OpenRouter on cloud
  setups. Hand-typed text has never left the Mac before, so `judgeFixes` is off by default.
- Learn now also sends accepted and `auto` captured fixes to the teacher and student models.
- README's Privacy section changes in the same commit as each phase.

## Tests

Per `AGENTS.md`: everything injected, nothing touches the user's files.

- **Unit:** `VocabularyStore` (file, reload), `Vocabulary.apply` (case, boundaries, Chinese,
  variant inside its own term, idempotent), `promptBlock` (cap, order, empty), `VocabularyPolish`,
  the Learn student and fingerprint, the 60-fix selection; `FixIntake` (changes, candidates, 3
  dictations, dismissed, backfill); `TypedEdit` (each key, each give-up), span extraction,
  `EditWatcher` with fake closures (every end condition, every never-armed case); `FixJudge` with
  a fake backend (batching, send rules, never while busy, verdict effects, `auto` rule), prune.
- **UI:** the Vocabulary page and the *Waiting for you* group with `HostedView`, plus snapshots.
- **Budgets** (`PerformanceTests`): `Vocabulary.apply` on a long dictation with 200 entries; the
  key path with no watch armed; `TypedEdit` per key. Idle CPU with `scripts/perf.sh` after phase 3.
- **Architecture:** new shared objects are made in `AppServices.live()`.
- `./test.sh --live`: one judge batch (phase 4).

## Measuring runs (approved by Mike, Nov 22)

Costs are from saved results, not `AGENTS.md`'s "$1 a run": the Oct 17 polish run was 110 requests
for $0.0077; a default latency run is about $0.003 (`bench/README.md`); a tune is about $0.50.

| Run | Decides | Cost |
|---|---|---|
| `bench/suite.py polish run`, one model, one round, with a sample vocabulary | Polish quality and wait with the terms block | about 1¢ |
| `./test.sh --local`, then the latency suite on the on-device model only, no polish | Whether `vocabularySpeechHint` can default on (the code notes English-first hint words made Qwen translate mixed Chinese) | $0 |
| `bench/suite.py edits run`: cheap models first, the strong one once as the reference, batches of 10 | The judge's model, and whether batching holds accuracy | est. under 15¢ |

The edits suite records each request's cost (as the polish suite does), prints the run's total, and
has a `--dry-run` that estimates it first.

## Not included

- Switching on Accessibility inside Electron apps so readback works there.
- Applying vocabulary in the bench's `--corrections` run (it measures the prompt alone).
- Tuning automatically: Learn stays a button.
- Hiding fixes that vocabulary already solves from the teacher: it still sees them, as already right.
