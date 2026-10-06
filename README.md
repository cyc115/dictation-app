# DictationApp — your Typeless replacement (on-device, $0)

Hold **Fn** to dictate into any app on your Mac. Release to paste.
Text streams live in a small overlay while you speak.
AI polish is **OFF by default** — toggle it in the menu bar when you want it.

## Install (one command)

```sh
zsh ~/DictationApp/build.sh
```

Then grant the 3 permissions when prompted:

1. **Microphone** — system prompt at launch
2. **Speech Recognition** — system prompt at launch
3. **Accessibility** — System Settings → Privacy & Security → Accessibility → enable DictationApp
   (needed for the Fn hotkey and pasting text)

Relaunch the app after enabling Accessibility.

## Use

- **Hold Fn**, speak, **release** → the transcript pastes at your cursor.
- Menu bar 🎙 → **AI polish (on-device)** toggles LLM cleanup (default: off).
  When on, Apple's on-device model removes fillers and fixes self-corrections —
  it never rewrites your meaning, and nothing leaves your Mac.
- Menu bar also has Start/Stop dictation if you prefer clicking.

## Privacy design

- The mic opens **only** while you hold Fn (or while menu-bar dictation is active) — never in the background.
- Transcription runs 100% on-device via Apple Speech (`requiresOnDeviceRecognition`).
- Your clipboard is saved before pasting and restored ~1s after, so nothing you copied is lost.

## Troubleshooting

- **Nothing happens on Fn**: Accessibility isn't enabled yet → enable it, relaunch.
- **"On-device recognition unavailable"**: System Settings → Keyboard → Dictation → make sure English dictation is enabled (downloads the on-device model).
- **AI polish does nothing**: Apple Intelligence must be available on this Mac; otherwise the toggle safely falls back to the raw transcript.
- **Paste lands in the wrong app**: click the target text field first, then hold Fn.

## Uninstall

Delete `/Applications/DictationApp.app` (or `~/Applications/DictationApp.app`) and remove it from
System Settings → Privacy & Security → Accessibility / Microphone / Speech Recognition.
