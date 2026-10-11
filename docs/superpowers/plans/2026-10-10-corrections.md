# Corrections (step 1) Implementation Plan

Spec: `docs/superpowers/specs/2026-10-10-corrections-design.md`. Executed inline in one session.

**Goal:** fix a dictation from History; keep raw text, app output and your fix on the history entry;
run the polish bench on them.

**Architecture:** `HistoryEntry` gains optional `raw`, `setup`, `prompt`, `correction`. `HistoryStore`
sets corrections and never prunes corrected entries. A new `CorrectionsView` lists
`store.corrections`; `HistoryRow` gets a pencil (or check). `MainTab.corrections` in the sidebar.
`bench/suites/polish.py` reads `history.json` as cases.

## Tasks

1. **Model + store** (`History.swift`, `ModelTests.swift`)
   - `HistoryEntry`: `raw`, `setup`, `prompt`, `correction: String?`; old JSON decodes.
   - `HistoryStore.add(text:duration:raw:setup:prompt:)` (raw kept only when it differs from text).
   - `setCorrection(_:for:)`: trims; empty → nil; saves. `corrections` = entries with one.
   - `prune()` keeps corrected entries. Tests for each.
2. **Record raw/setup/prompt** (`AppDelegate.swift`): remember the setup at start; `deliver` passes
   raw, setup id, and the prompt when polished.
3. **History row + Clear All** (`History.swift`, `UITests.swift`): pencil beside Copy (check when
   corrected) calling `onCorrect(entry.id)`; Clear All dialog counts corrections. UI test.
4. **Corrections tab** (`Corrections.swift` new, `MainWindow.swift`, `UITests.swift`): cards with
   setup · prompt, left text with changed words highlighted orange (`changedRanges`), right
   `TextEditor` saving as you type, "Before polish" disclosure, delete, search, footer link to
   history.json in Finder; a card stays while focused even if emptied. Sidebar tab with count badge;
   pencil switches to it. Unit test for the word diff, UI test, snapshots for both tabs.
5. **Bench** (`bench/suites/polish.py`, `bench/test_polish.py`, `bench/README.md`): `load_cases`
   turns a history.json list into cases; `--corrections [PATH]`; results keep the file's full path.
6. **Verify + ship:** `./test.sh`, bench tests, `./build.sh --keep-running`, README line, commit,
   push to main.
