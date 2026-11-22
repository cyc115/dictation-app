# Custom vocabulary, phase 3 Implementation Plan

Spec: `docs/superpowers/specs/2026-11-22-custom-vocabulary-design.md` (Phase 3: the edit watcher,
Captured fixes in History). Executed inline in one session on `cyc_vocabulary_3`, test first,
`./test.sh` green at each commit.

**Goal:** with *Learn from my edits* on, the way you edit a dictation right after it's pasted is
kept as a captured fix on its History entry, waiting in Corrections for Accept or Dismiss. No model
call; nothing is added to the paste or to a keystroke.

**Architecture:** two pure pieces and one small state machine.
- `TypedEdit` (keystroke mode): the pasted text plus what's typed after it, a cursor and a
  selection, in memory. Applies `EditKey`s (text, ⌫, ⌦, ←/→, ⌥←/⌥→, ⌥⌫, ⇧-selections); anything it
  can't follow (another shortcut, a move into text it never saw, a word move over Chinese) gives
  up. Text typed at the span's end belongs to it up to the first space or sentence mark.
- `SpanTracker` (readback mode): the box's value and the span's UTF-16 range. Each read is diffed
  against the last (common prefix and suffix): a change before the span shifts it, one inside it
  grows or shrinks it, one after it is outside (an insertion at its end, past the first space or
  sentence mark). A change that crosses the span's edge, takes all of it, or leaves fewer than half
  the paste's words (unless the keys agree) can't be told apart: the watch ends on the last good read.
- `EditWatcher` (made once in `AppServices`, handed to `DictationController.editWatcher`):
  `arm(spot, pasted, text, entry)`, `endNow()`; every step that touches the Mac is a closure (`read`,
  `isSecureField`, `secureInput`, `inputMethodActive`, `bundleID`, `listen` for keys, `watchClicks`,
  `watchApps`, `now`, `after`, `background`, `toMain`). Arming costs nothing on the main thread: the probe runs 0.15 s later
  (the app has taken the ⌘V by then) on a background queue; keys typed meanwhile go into a
  `TypedEdit` so nothing is lost if the probe fails. Pause reads (0.7 s after the last key) run in
  the background too. Only the read before a Return blocks the key, capped at 50 ms (a background
  read waited on with a timeout); comparing that read and storing the capture wait until the Return
  has been passed on. Readback mode also keeps a `TypedEdit`, to trim text typed right after the span
  when the keys agree with the box, and reads the box on a click and 0.3 s after it.
- Keys: `HotkeyManager.handleTap` (the existing tap, which sees every key-down before the app does)
  calls `onKey` when it's set, skipping this app's own keys (`syntheticMarker`: the paste's ⌘V
  reaches the tap after the watch is armed). Nil when no watch is armed: one check. Not fed from
  the global monitor as well, so no key is applied twice. Mouse clicks (keystroke mode's give-up)
  come from a passive monitor installed only while a keystroke-mode watch runs, so clicks never
  go through the tap.

**Data:** `HistoryEntry.capture: Capture?` (`edited`, `mode`, `app`, `state`), decoded tolerantly
(an unknown state from a newer build reads as `dismissed`, an unknown mode as `keystrokes`).
`fixTarget` = `correction`, else the capture's `edited` unless it's dismissed: what intake,
candidates and the staleness guard compare with, instead of `correction`.

## Tasks

1. **History** (`HistoryStore.swift`, `HistoryTests`)
   - `Capture`; `add` returns the new entry's id; `setCapture(_:for:)` (only on an entry with no
     correction and no capture); `accept(id)` (correction = edited, `accepted`); `dismiss(id)`
     (`dismissed`; an `auto` one loses its correction).
   - Typing a correction on a captured entry makes it `accepted`; removing it makes it `dismissed`.
   - `prune` keeps a correction unless its capture is `auto`; waiting and dismissed captures go
     with their entry.
   - `fixTarget`; `setIntakes`, `VocabularyIntake.work`/`fixes`, `CandidateTally` and the
     ordinary-word guard use it. Old history.json decodes; bench fixture gains a waiting capture.
2. **Learn** (`LearnController.swift`): the 60 fixes are manual and accepted first, newest first,
   then `auto`; `yours`/`captured` counts; the tile says "N yours · M captured" when M > 0.
3. **TypedEdit, EditKey, SpanTracker** (`Vocabulary/TypedEdit.swift`, `Vocabulary/SpanTracker.swift`,
   `EditWatcherTests`): each key, each give-up, the span's end, `EditKey(event)` from a CGEvent.
4. **EditWatcher** (`Vocabulary/EditWatcher.swift`): never armed (setting off, excluded app, secure
   field, secure input; the controller's own: command, dictate-and-send, taken back, not in
   History); readback probe; keystroke fallback (keys typed before the probe replayed); ends on
   focus or app change, Return, new dictation, 30 s without a key, 2 minutes; dropped on secure
   input; no capture without word changes. `EditWatchStats` (per app: armed, probes failed,
   keystroke give-ups) in `edit-watch.json`, counts and app names only.
5. **Wiring** (`TextInjector.inject` returns what it pasted, `DictationController.type/deliver`,
   `HotkeyManager.onKey`, `AppDelegate`): arm after `history.add` on the plain-paste branch; a new
   dictation ends the watch from what it has (no read in `start()`); a capture schedules the idle
   pass. Setting `learnFromEdits` (off).
6. **UI** (`CorrectionsView.swift`, `LearnView.swift`, `VocabularySection.swift`): *Waiting for you*
   (what the app wrote, your edit, Accept, Dismiss), "captured" badge, Learn tile counts, Settings
   row and the per-app counts under it. UI tests (`HostedView`) + snapshot `corrections-waiting`.
7. **Budgets** (`PerformanceTests`): `handleTap` on a key-down with no watch; `TypedEdit` per key;
   the armed key path in readback mode.
8. **Privacy test**: text outside the span and typed after it never reaches history.json or
   edit-watch.json.
9. **Docs + gate**: README (feature, Privacy), spec (as built), `docs/command-line.md`; `./test.sh`;
   bench pytest; `mike:pre-pr`.
