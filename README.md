# DictationApp — your Typeless replacement (on-device, $0)

Hold **Fn** (or another hotkey you pick) to dictate into any app on your Mac. Release to paste.
A small bar at the bottom of the screen shows a live waveform while you speak,
with ✕ (cancel) and ✓ (paste) buttons.
AI polish is **OFF by default** — toggle it in the menu bar when you want it.

## Install (one command)

```sh
./build.sh   # builds, quits any running copy, installs, relaunches
```

Then grant the 3 permissions when prompted:

1. **Microphone** — system prompt at launch
2. **Speech Recognition** — system prompt at launch
3. **Accessibility** — System Settings → Privacy & Security → Accessibility → enable DictationApp
   (needed for the Fn hotkey and pasting text)

Relaunch the app after enabling Accessibility.

## Use

- **Hold Fn**, speak, **release** → the transcript pastes at your cursor.
- Menu bar 🎙 → **Settings…** (⌘,):
  - **Hotkey**: Fn, Right ⌘, Right ⌥, Right ⌃ or Right ⇧.
  - **Activation**: hold to talk, or tap once to start and tap again to paste.
    Pressing another key while the hotkey is down (e.g. Right ⌘+C) counts as a shortcut, not dictation.
  - **Mouse trigger**: middle, button 4 or button 5 — press to start, press again to paste.
    The button's normal action (e.g. Back) is blocked while it's assigned.
- Menu bar 🎙 → **Insights…**: words dictated, time saved (vs. typing at 40 WPM), average WPM, total dictation time.
- Menu bar 🎙 → **History…** (⌘Y): past dictations by day, searchable; hover a row to copy it.
  Kept on this Mac only (`~/Library/Application Support/DictationApp/history.json`); choose how long to keep it.
- Click ✕ (or press **Esc**) to throw the dictation away, ✓ to stop and paste.
- **Type as you speak** (Settings → Output, off by default): each phrase is typed into the focused app as soon as you pause, instead of one paste at the end.
- The bar shows which microphone is recording, under the waveform.
- Menu bar 🎙 → **AI polish (on-device)** toggles LLM cleanup (default: off).
  When on, Apple's on-device model removes fillers and fixes self-corrections —
  it never rewrites your meaning, and nothing leaves your Mac.
- Menu bar also has Start/Stop dictation if you prefer clicking.

## Development

```sh
./test.sh          # unit, UI, snapshot and performance-budget tests
./test.sh --perf   # + launch time / idle CPU / memory of the installed app
scripts/e2e-speech.sh  # real recognizer on a synthesized 24 s dictation with pauses
./build.sh         # build, install to /Applications, relaunch
```

- **UI tests** host the real SwiftUI views in an offscreen window and drive them through the
  accessibility tree with real mouse clicks (`Tests/DictationKitTests/UITests.swift`).
- **Snapshot tests** compare rendered views to `Tests/DictationKitTests/__Snapshots__/*.png`.
  After an intentional UI change: `RECORD_SNAPSHOTS=1 ./test.sh --filter SnapshotTests`.
- **Performance tests** fail if hot paths (mic level per buffer, waveform redraw, overlay show,
  history load/save) exceed their budgets; `scripts/perf.sh` checks the running app.

## Privacy design

- The mic opens **only** while you hold Fn (or while menu-bar dictation is active) — never in the background.
- Transcription runs 100% on-device via Apple Speech (`requiresOnDeviceRecognition`).
- Your clipboard is saved before pasting and restored ~1s after, so nothing you copied is lost.

## Troubleshooting

- **Nothing happens on the hotkey**: Accessibility isn't enabled yet → enable it, relaunch.
  `build.sh` signs with a stable local cert, so the permission survives rebuilds.
- **Fn also opens the emoji picker / Apple Dictation**: System Settings → Keyboard →
  "Press 🌐 key to" → Do Nothing, or pick a different hotkey.
- **"On-device recognition unavailable"**: System Settings → Keyboard → Dictation → make sure English dictation is enabled (downloads the on-device model).
- **AI polish does nothing**: Apple Intelligence must be available on this Mac; otherwise the toggle safely falls back to the raw transcript.
- **Paste lands in the wrong app**: click the target text field first, then hold Fn.

## Uninstall

Delete `/Applications/DictationApp.app` (or `~/Applications/DictationApp.app`) and remove it from
System Settings → Privacy & Security → Accessibility / Microphone / Speech Recognition.
