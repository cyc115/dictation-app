# DictationApp

Fast dictation for macOS — on-device, or in the cloud for English mixed into Chinese.

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
- **Corrections:** in History, click the pencil beside a dictation that came out wrong and type what you
  wanted. Each correction keeps the speech model's text, what the app wrote and your fix on that History
  entry, kept until you delete it. `bench/suite.py polish run -m setup:cloud-flash --corrections` tests a
  setup or prompt on them.
- Click ✕ (or press **Esc**) to throw the dictation away, ✓ to stop and paste.
- **Model** (Settings → Model) picks a *setup*: the speech model, the AI polish model and the polish
  prompt, together:
  - *On-device* — runs on your Mac, English or 中文 (one at a time); polished on-device too.
  - *Cloud Flash* — text in ~0.5 s after you stop; handles English mixed into Chinese.
  - *Cloud Big* — text in ~2 s; handles English mixed into Chinese.

  Cloud models ask for an API key (saved in `~/Library/Application Support/DictationApp/secrets.json`, readable only by your user account; shared by every cloud setup) and send audio when you
  stop. Settings that a model can't use are greyed out and marked *Unavailable*; your choice is kept.
  (Each setup's models and prompt are in `DictationSetup.builtInJSON`, `Sources/DictationKit/Setups.swift`;
  how they compare is in `bench/`.)
- **Your own setups**, to try another combination in the app: add them to
  `~/Library/Application Support/DictationApp/setups.json` and they appear after the built-in ones
  (the file is re-read whenever Settings opens; problems show under Model):

  ```json
  {"setups": [
    {"id": "flash-v2", "title": "Flash, v2 prompt",
     "speech": "openrouter:qwen/qwen3-asr-1.7b", "backup": "qwen/qwen3-asr-0.6b", "backupWait": 2,
     "polish": "openrouter:openai/gpt-oss-120b@Groq", "prompt": "v2"},
    {"id": "mac-my-prompt", "title": "On-device, my prompt",
     "speech": "apple", "polish": "apple", "prompt": "~/prompts/mine.txt", "wrap": false}
  ]}
  ```

  `speech`: `apple` or `openrouter:<model id>`. `polish`: `apple` or `openrouter:<model id>[@Provider]`.
  `prompt`: `v1`, `v2`, `v3` (`bench/polish_prompts/`) or a text file. Optional: `summary`, `backup`
  (an OpenRouter model also asked when the speech model is slow) and `backupWait` (seconds, default 2),
  `wrap` (transcript in `<transcript>` tags, default true). Benchmark one with
  `bench/suite.py polish run -m setup:<id>`.
- **Type as you speak** (Settings → Output, off by default): each phrase is typed into the focused app as soon as you pause, instead of one paste at the end.
- The bar shows which microphone is recording, under the waveform.
- **Keep recordings** (Settings → Recordings, off by default): saves each dictation's audio and
  transcript on this Mac, to use as a benchmark set (`bench/README.md`).
- **Backup model when slow** (Settings → Model, on by default; cloud setups): if Cloud Flash hasn't
  answered in 2 s, a smaller, faster model is asked too and the first answer is used (Cloud Big:
  Cloud Flash after 4 s); after a slow answer both are asked at once for 5 minutes. Faster in slow
  spells, but the smaller model gets more technical terms wrong. Off, only the chosen model is asked.
- Menu bar 🎙 → **AI polish** toggles LLM cleanup (default: off). It removes fillers and fixes
  self-corrections without rewriting your meaning. The setup picks the polish model; every
  built-in setup uses the v3 prompt with the transcript in `<transcript>` tags:
  - **On-device** → Apple's on-device polish: nothing leaves your Mac (about 1 s, up to 3 s
    on long paragraphs).
  - **Cloud Flash / Cloud Big** → cloud polish (gpt-oss-120b on Groq through OpenRouter, about
    0.4 s), which also passed far more of the polish tests (`bench/results/polish/README.md`).

## Development

```sh
./test.sh          # unit, UI, snapshot and performance-budget tests
./test.sh --perf   # + launch time / idle CPU / memory of the installed app
scripts/e2e-speech.sh  # real recognizer on a synthesized 24 s dictation with pauses
bench/suite.py latency run   # wait after you press stop, per speech/polish model (p50/p90/p95)
./build.sh         # build, install to /Applications, relaunch
./build.sh --keep-running   # install without quitting the running app; new build on next open
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
- Audio is deleted once transcribed, unless you turn on Keep recordings (stored only on this Mac).
- Your clipboard is saved before pasting and restored ~1s after, so nothing you copied is lost.

## Troubleshooting

- **Nothing happens on the hotkey**: Accessibility isn't enabled yet → enable it, relaunch.
  `build.sh` signs with a stable local cert, so the permission survives rebuilds.
- **Fn also opens the emoji picker / Apple Dictation**: System Settings → Keyboard →
  "Press 🌐 key to" → Do Nothing, or pick a different hotkey.
- **"On-device recognition unavailable"**: System Settings → Keyboard → Dictation → make sure English dictation is enabled (downloads the on-device model).
- **AI polish does nothing**: with On-device polish, Apple Intelligence must be available on this Mac; with Cloud, the cloud API key must be valid. Either way a failed polish pastes the raw transcript.
- **Paste lands in the wrong app**: click the target text field first, then hold Fn.

## Uninstall

Delete `/Applications/DictationApp.app` (or `~/Applications/DictationApp.app`) and remove it from
System Settings → Privacy & Security → Accessibility / Microphone / Speech Recognition.
