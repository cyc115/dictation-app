# Custom vocabulary, phase 2 Implementation Plan

Spec: `docs/superpowers/specs/2026-11-22-custom-vocabulary-design.md` (Phase 2: intake). Executed inline
in one session on `cyc_vocabulary_2`, test first, `./test.sh` green at each commit.

**Goal:** the words you fix in Corrections become vocabulary on their own: a term fixed in 3
different dictations is learned, with what the app wrote instead as its variants unless that's an
ordinary word. No model call; nothing runs while a dictation is in progress.

**Architecture:** three pure pieces and one small scheduler.
- `WordDiff.hunks` (one walk over the diff; `changed` is rebuilt on it) → `FixIntake.changes(from:to:)`:
  each replaced run, as substrings of the two texts, edge punctuation trimmed.
- `Intake` on `HistoryEntry` (`of`, `changes`, each with an optional `verdict` for phase 4).
- `CandidateTally.support(in:)`: History (with intake) → one candidate per term (case-folded), each
  `heard` with its dictation ids and an `ordinary` flag from the guard. The guard scans the
  uncorrected dictations once with `Vocabulary.Finder` (the replacement's own matcher, pulled out of
  `apply`). Recomputed in full every pass, so deleting a correction lowers a count.
- `VocabularyStore` keeps candidates in vocabulary.json beside the entries; `updateCandidates` merges
  the support with what's persisted (dismissed, handed over) and learns terms at the threshold;
  `learn` (Add now) and `dismiss`.
- `VocabularyIntake` (made once in `AppServices`): the idle pass. One re-armable 30 s timer, re-armed
  by `DictationController.onIdle` and at launch, re-checks `isBusy` when it fires; the Vocabulary and
  Corrections tabs run it when shown (not while busy). The work runs on a background queue from a
  snapshot; results are applied on the main thread, dropped if a dictation started meanwhile.

**Refactor first:** `WordDiff` moves out of `CorrectionSuggester.swift` into its own file with `hunks`;
`VocabularyStore.change`/`load` work on the whole `File` (entries + candidates), so `add`,
`recordUses` and the command line carry candidates through the same re-read-then-save path.

## Tasks

1. **WordDiff + FixIntake** (`History/WordDiff.swift`, `Vocabulary/FixIntake.swift`, `FixIntakeTests`)
   - `hunks(from:to:)`: removed and inserted word ranges between common words; `changed` on it.
   - Changes: replaced runs only (insert-only/delete-only give none); Chinese, mixed; punctuation
     trimmed at the edges; equal-after-trim dropped; word counts kept for the 4-word rule.
2. **History** (`HistoryStore.swift`): `intake: Intake?`; `setIntakes([UUID: Intake?])`, one publish
   and one save. Old history.json decodes; bench's `--corrections` fixture gains an `intake` key.
3. **Finder** (`Vocabulary.swift`): every match of a list of phrases, the replacement's rule.
4. **Candidates** (`Vocabulary/VocabularyCandidates.swift`, `VocabularyStore.swift`, `CandidateTests`)
   - By term across different `heard`s; one dictation counted once; at most 4 words a side.
   - Guard: a `heard` standing (not as its term) in 3+ uncorrected dictations is ordinary: doesn't
     count, never a variant; a *misheard* verdict counts it anyway, still no variant.
   - Store: `candidates` (decodeIfPresent), `updateCandidates(support, learnAfter:)` (nil = Use
     vocabulary off: collect, don't add), `learn(id)`, `dismiss(id)`. A dismissed term never comes
     back; a term or variant handed over once is never handed over again (so one you delete stays
     deleted). No save while the file is unreadable, none when nothing changed.
   - Setting `vocabularyLearnAfter` (Int, 3, no row, at least 1).
5. **Idle pass** (`Vocabulary/VocabularyIntake.swift`, `AppServices`, `AppDelegate`, `MainWindow`)
   - Fakes for the timer, the queue and `isBusy`: not while busy; 30 s after the last dictation;
     tab shown; backfill on the first pass; only entries whose target differs from `intake.of`.
   - `assertFaster`: support over 2,000 entries, 100 candidates.
6. **Page** (`VocabularyView.swift`): "Seen in your edits" above Your terms: term, variants, "2 of 3",
   Add now, dismiss; candidates seen in 2+ dictations (or judged misheard), the rest behind
   "Show all (n)"; hidden when empty. UI test + snapshot `vocabulary-candidates`.
7. **Docs + gate**: README (vocabulary section, Privacy); `./test.sh`; bench pytest; `mike:pre-pr`.
