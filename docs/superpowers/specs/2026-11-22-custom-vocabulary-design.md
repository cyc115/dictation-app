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
- **Terms block** (`Vocabulary.promptBlock`), most used first, then newest: one guard sentence
  (`Vocabulary.promptHeader`: write a term only where the transcript has a sound-alike that makes
  no sense; never change a word that already makes sense) and the terms, one a line, **without**
  their "heard as" variants. It goes before the prompt's closing "Output only…" paragraph. Measured
  Nov 22 (`bench/results/polish/README.md`): the first version, a "write these exactly" list with
  variants at the end, cost the general set 4 points twice running; this one is within noise of no
  vocabulary. With no enabled terms nothing is added, so the request is identical to today's.
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
- v7's baked-in terms stay in v7. The backfill does **not** bring them into vocabulary: a dry run
  on Mike's History (Nov 22) found 39 candidates, each seen once, and added no entry. Vocabulary
  starts empty; terms come in by hand, by **Add now**, or after 3 dictations.

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
    sides are at most 4 words with no sentence punctuation inside ("file two" → "file. Two" is
    formatting; 34 of 72 changes in Mike's History were) and `heard` isn't an ordinary word (below).
  - A term seen in **3 different dictations** (`vocabularyLearnAfter`, no Settings row) becomes a
    learned entry. **Add now** does it at once. A dismissed term never comes back.
  - **Ordinary-word guard:** a `heard` that also stands in 3 or more dictations you didn't correct
    is an ordinary word ("two", "cloud"). It never becomes a `heardAs` variant: replacing it
    everywhere would break the dictations where you meant it. The term is still learned, without
    that variant, so polish and the speech hint can pick it by context.
  - The page lists candidates seen twice or more, or judged *misheard*; the rest sit behind
    "Show all".
- **As built** (rules the first draft of this spec didn't have):
  - Sentence punctuation, quotes and brackets are trimmed from a change's edges ("cloud." →
    "Claude." is cloud → Claude); "C++" keeps its symbols. `heard` variants merge regardless of
    case, and a `heard` written exactly as its term isn't counted by the ordinary-word guard, so
    a case fix ("remarkable" → "reMarkable") can be learned.
  - **After a term is learned,** a new variant needs 2 dictations of its own or a *misheard*
    verdict: one change of mind ("GPT" → "Claude") mustn't replace "GPT" everywhere. At the
    first learn, variants seen once still go in.
  - Candidates remember `added` and `addedHeard`, and dismissed or added ones stay in the file
    with nothing left to count, so a learned term or variant you delete doesn't come back.
  - A pass whose corrections changed while it worked is dropped and retried 30 s later (a learn
    can't be undone). The first pass runs 30 s after launch. The pass never moves an unreadable
    `vocabulary.json` aside; only something you do does.
- **Backfill:** the first idle pass covers every existing correction. On Mike's Mac (28
  corrections, dry run on a copy, Nov 22) that gives 39 candidates, each seen once, and no entry.
  Rules alone learn slowly; the judge (phase 4) is what tells a misheard term from a style change.

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

### Phase 3 as built

Decisions the draft didn't make; where it was silent, the choice keeps less, learns less, or never
delays typing.

- **Vocabulary's target** is `HistoryEntry.fixTarget`: `correction`, else the capture's `edited`
  unless it's `dismissed`. A waiting capture counts toward candidates (every guard unchanged); a
  dismissed one counts for nothing. `intake.of`, the idle pass, its staleness guard and the
  ordinary-word guard all compare with it (a dictation with a captured edit isn't "left alone").
  A capture saved at idle schedules the idle pass.
- **Your correction wins:** one capture per dictation, never on a corrected one, none when History
  is off (no entry to keep it on). Deleting the correction on a captured entry dismisses the
  capture, so its edit doesn't go on feeding vocabulary unseen. A correction typed on a dismissed capture is
  simply yours (it stays dismissed; "captured" and the tile count only `accepted` and `auto`). The History pencil on a waiting
  dictation opens it in Corrections as it is (no correction started from what the app wrote).
- **Timing:** arming does no Accessibility call; the probe runs 0.15 s after the paste (the app
  takes the ⌘V asynchronously) on a background queue, and keys typed before it has an answer go
  into a `TypedEdit`, so none is lost if it fails. Pause and final reads are off the main thread
  too. The read before a Return is a background read waited on for at most 50 ms; comparing it
  with the last read and saving the capture wait until the Return has gone on. A new dictation ends the watch from what it has, with no read
  in `start()`; an app change and the time limits do one last background read.
- **Keys** come from the event tap only (it sees each key before the app; the global monitor would
  apply each twice), skipping the app's own `syntheticMarker` keys: the paste's ⌘V reaches the tap
  after the watch it starts. Clicks (keystroke mode's give-up) come from a passive monitor that
  exists only while a keystroke-mode watch runs, so clicks never go through the tap. Return means
  ↩, ⇧↩, ⌘↩ and keypad Enter alike.
- **The span's edges:** text typed right at the end of the pasted text belongs to it up to the
  first space, or up to and including a Chinese sentence mark (so a retyped "Claude." keeps its
  period); the rest, and anything typed after it, isn't part of the edit. Text typed right at its
  start is the dictation's (only the run touching it) when nothing was put in front of the paste
  (an empty box, or after a space). In readback, a read whose change crosses the span's edge or
  takes all of it (the box cleared by a send button, a selection reaching past it) ends the watch
  on the last good read, and so does one that leaves fewer than half the paste's words in the span,
  or brings in more than one new word beyond those it took out, unless your keys say that's what
  you typed (sent, then a new message typed by hand, is not an
  edit; a one-word dictation retyped after selecting it with the mouse is lost to this). A click
  reads the box at once (a send button acts on mouse-up, so that's the box before it) and again
  0.3 s later (an emptied box ends the watch). Readback keeps a `TypedEdit` alongside: when your keys agree with the box,
  they trim text typed after the span in the same burst ("cloud." → "Claude. and more" with no
  pause); when they don't (autocorrect, an app's own completion), the read stands, which can keep
  text typed onto the last word without a space (Chinese has none).
- **Ended before the probe answered** (Return within 0.15 s of the paste), nothing is kept: it
  hadn't checked for a password field yet. The Enter button's own Return (a key the tap skips) ends
  the watch too.
- **Keystroke mode** also gives up on a move or delete into text it never saw (before or after the
  paste), a word move over Chinese (apps split it with a dictionary), ↑/↓, Tab, Esc and dead keys.
  ⌥⌫ and ⌥←/→ follow the Mac's word rule (letters, digits, apostrophes).
- `edited` is stored without surrounding whitespace (the paste's leading space).
- **Files:** a capture state or mode a newer build wrote reads as `dismissed`/`keystrokes`, one
  without text as `dismissed`, so history.json loads and nothing unknown trains. An older build
  ignores `capture` (it keeps accepted ones as plain corrections). The counts are in
  `edit-watch.json` (app names and numbers only), shown under the setting while it's on; a watch
  counts as armed once the probe has found the box isn't a password field.
- The Learn tile's "N yours · M captured" shows only once M > 0.
- **Deleting and dictating again leaves nothing:** words only removed are no change (`FixIntake`), so
  a dictation cut short or deleted whole before the next one is never a capture.
- **Checked on a real text box (2026-11-22):** TextEdit only, with the real paste, real key events
  and real Accessibility reads: the probe chose readback and "I use cloud" → "I use Claude" was
  captured. Not checked: Electron and browser text boxes, password fields, input methods, and
  keystroke mode in a real app; the per-app counts in Settings say which mode each app gets.

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
| `bench/suite.py polish run`, one model, with a sample vocabulary: **done Nov 22**, the block was reworded and moved | Polish quality and wait with the terms block | 10¢ in all |
| ~~`./test.sh --local`, then the latency suite on the on-device model only, no polish~~ **Done Nov 22**, as one run of `LocalEngine` on the 46 test clips and 8 term clips with 0, 10 and 50 terms (neither suite passes vocabulary terms). No harm on the test clips (5.3% → 5.1% word errors, no new translation), term clips 23% → 6% errors, +0.04 s with 10 terms and +0.17 s with 50. `bench/results/local/README.md`. The default stays off until Mike decides | Whether `vocabularySpeechHint` can default on (the code notes English-first hint words made Qwen translate mixed Chinese) | $0 |
| `bench/suite.py edits run`: cheap models first, the strong one once as the reference, batches of 10 | The judge's model, and whether batching holds accuracy | est. under 15¢ |

The edits suite records each request's cost (as the polish suite does), prints the run's total, and
has a `--dry-run` that estimates it first.

## Not included

- Switching on Accessibility inside Electron apps so readback works there.
- Applying vocabulary in the bench's `--corrections` run (it measures the prompt alone).
- Tuning automatically: Learn stays a button.
- Hiding fixes that vocabulary already solves from the teacher: it still sees them, as already right.
