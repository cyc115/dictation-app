# Custom vocabulary, phase 1 Implementation Plan

Spec: `docs/superpowers/specs/2026-11-22-custom-vocabulary-design.md` (Phase 1 only). Executed inline
in one session on `cyc_vocabulary`, test first, `./test.sh` green at each commit.

**Goal:** terms you add (with what the recognizer writes instead) are fixed in every dictation,
told to polish, and used by Learn's student; managed on a Vocabulary page, in Settings and from
the command line. No model call is added; the only added wait is a local string replacement.

**Architecture:** a value snapshot `Vocabulary` (the enabled entries, matchers built once) does the
work: `apply` (replacement + uses), `promptBlock`, `instructions(_:)` (the one helper: a prompt +
the block), `speechWords`, `fingerprint`. `VocabularyStore` (made once in `AppServices.live()`)
owns `vocabulary.json` and hands out snapshots, reloading when the file's modification date changed.
`VocabularyPolish` wraps a backend (replaces input and output, forwards `prepare()` and `name`).

**Refactor first:** `DictationController.deliver` has two copies of type → History → finished
(polished, not polished); fold them into one path so replacement before and after polish is one
change. `DictationSetup.polishBackend/polishService` take the snapshot, so main, backup and
on-device all get their instructions from `Vocabulary.instructions`.

## Tasks

1. **Core** (`Vocabulary/Vocabulary.swift`, `VocabularyTests.swift`)
   - `VocabularyEntry` (spec fields; `Source` .manual/.learned). `Vocabulary(entries:)` keeps enabled ones.
   - `apply(_:) -> (text, uses: [UUID: Int])`: longest variant first; Latin case-insensitive at
     boundaries (a neighbour that is a Latin letter or digit; Han neighbours are fine); Han variants
     literal; skipped where a term already stands; one scan of the original text, so idempotent.
   - `promptBlock` (most used, then newest; max 100; "" when empty), `instructions(_:)`,
     `speechWords` (max 50), `fingerprint` (SHA-256 of the enabled entries; nil when empty).
   - `assertFaster` for `apply`: 200 entries, a long dictation.
2. **Store** (`VocabularyStore.swift`): `entries`, `add(term:heardAs:)` (merges into an existing term),
   `update`, `remove(id:)`, `remove(term:)`, `recordUses`, `reloadIfChanged()`, `vocabulary(enabled:)`.
   `AppServices` makes it; `AppFilesTests` lists its file.
3. **Settings** (`Settings.swift`): `vocabularyEnabled` (on), `vocabularySpeechHint` (off).
4. **Live path** (`DictationController.swift`, `Setups.swift`, `DictationControllerTests.swift`)
   - Snapshot at start (reloads); `makePolish(setup, vocabulary)`; speech hint words for plain
     dictation on on-device engines when the setting is on.
   - `deliver`: replace → polish (instructions + block) → replace → paste → History (`raw` as heard)
     → `recordUses`. Tests: no terms = today's request and paste; failed/empty/timed-out polish
     pastes replaced text; uses saved after the paste; polish off replaces too.
5. **Every backend from a setup**: backup, on-device, `CorrectionSuggester` (wrapped in
   `VocabularyPolish`), `LatencyProbe` (`.none`: the bench measures the prompt alone).
6. **Learn** (`LearnController.swift`, `LearnedPrompts.swift`, `PromptTunerTests`/`LearnUITests`)
   - `makeTuner(setup, key, vocabulary)`; one snapshot per tune; case inputs replaced; the student is
     `VocabularyPolish` over a backend with `instructions(candidate)`; the teacher's prompt untouched.
   - `PromptMeasurement.vocabulary` fingerprint; another one is stale (re-measured).
   - At most 60 fixes, newest first; the gate's "all learned" asks about the same 60.
7. **UI** (`VocabularyView.swift`, `VocabularySection.swift`, `MainWindow.swift`, `SettingsView.swift`)
   - `MainTab.vocabulary` (toolbar search); add row; Your terms (chips, source, uses, switch,
     delete, click to edit); footer link to the file. Settings › Vocabulary with Manage Vocabulary….
   - UI tests (`HostedView`, identifiers `vocabulary.*`), snapshot `vocabulary`.
8. **Command line** (`VocabularyCommand.swift`, `main` entry, `docs/command-line.md`): `list [--json]`,
   `add <term> [--heard a,b]`, `remove <term>`; tests with captured output.
9. **Docs + gate**: README (feature, Privacy, folder list), AGENTS.md folder list; `./test.sh`;
   `mike:pre-pr`.
