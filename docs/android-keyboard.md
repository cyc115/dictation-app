# Android keyboard

An Android keyboard (input method) with the Mac app's cloud dictation, in `android/`. It looks
like Typeless: it opens on one big **tap-to-speak** button and switches to English or 拼音 keys
from its top bar. Both key layouts have swipe typing.

- **Dictation.** One tap starts, one tap finishes. It uses the Mac app's Cloud Flash or Cloud
  Big setups: the same speech models, backup model when slow, polish model, provider order,
  prompt (v7), `<transcript>` tags, 0.8 s polish backup and 6 s polish deadline. **AI polish is
  on by default** (off on the Mac). The ✎ button turns it off.
- **Mic key** on the English and 拼音 layouts: dictate from the keys, then you're back on them.
- **English.** Tap or swipe. Completions for the word being typed, other readings of a swiped
  word, and a capital letter at the start of a sentence.
- **拼音.** Tap or swipe pinyin, then pick the Chinese: the likeliest sentence for all of it, words
  spelled exactly so, words it's the start of (`zhongg` → 中国), then words for its first syllables.
  Space takes the first; Enter keeps the letters.

## What the two apps share, and how

**Decision (Oct 17, 2026): the Android app reads the Mac app's setups and prompts from
`Sources/DictationKit/Setups.swift` at build time. The code isn't shared: the cloud logic (about 450
lines with the recorder) is ported to Kotlin, with the Mac app's tests ported alongside.**

| Option | One copy of | Cost | Verdict |
|---|---|---|---|
| **A. Shared spec, ported logic** (chosen) | Models, providers, waits, deadlines, prompts | ~450 lines of Kotlin with the Mac's tests ported; no change to the Mac app | Fits: the tuned part is data, the logic is small and settled |
| B. Kotlin Multiplatform core | Logic and data | Rewrite the Mac's tested cloud path in Kotlin; Gradle and Kotlin/Native in `build.sh`; async Swift interop through a plugin; can't be built or tested off a Mac | Too much churn for ~450 lines |
| C. Rust core (UniFFI) | Logic and data | As B, plus HTTP and async across FFI | Overkill |
| D. Homelab dictation gateway | Logic, data, and learned prompts | One more network hop on every dictation; dictation stops when the homelab or the tailnet is down; a service to run and back up | Worth it only to keep the API key off the phone or share learned prompts (below) |

How A stays in sync:

- `ExtractSpec` (`android/app/build.gradle.kts`) parses `DictationSetup.builtInJSON` and every
  `PolishPrompt` version out of `Setups.swift` the same way `bench/suites/polish.py` does, into
  the APK's `assets/spec/`. Change a model, wait or prompt in Swift, and the next Android build
  sends it too.
- `SpecTest` checks that each extracted prompt is identical to `bench/polish_prompts/<v>.txt`, the
  file `bench/test_polish.py` checks against Swift. A Swift edit the extractor misreads fails
  the Android build.
- `.github/workflows/android.yml` runs the Android tests on every change to `Setups.swift`,
  `bench/polish_prompts/` or `android/`, so a Mac-side edit can't break the phone silently.
- What's ported is the logic: `OpenRouter.kt` (requests, errors, `cleanup`), `Race.kt`
  (`FirstAnswer`, `AdaptiveBackup`) and `Dictation.kt` (`UploadRace`, `PolishService`), each with
  the Mac tests that cover it.

Follow-ups, when they're worth it:

- Move the spec out of Swift into `spec/setups.json` + `spec/prompts/` and load it as a SwiftPM
  resource on the Mac. That's cleaner than parsing Swift, but it changes `build.sh`, so do it
  on the Mac where `./test.sh` can check it.
- Learned prompts (Corrections → Learn) stay on the Mac. The phone always uses the built-in
  prompt. Sharing learned prompts is the one good reason for option D.

## Not ported

On-device speech and Apple Intelligence polish (Mac-only), history, corrections and learning,
insights, kept recordings, intelligent mic selection, and type-as-you-speak.

## Security

- The OpenRouter key is AES-GCM encrypted with a key in the Android Keystore, and kept out of
  backups and phone-to-phone transfers (`data_extraction_rules.xml`). Use a separate key with a
  credit limit (openrouter.ai → Keys), so a lost phone costs at most that limit.
- **Password fields** never offer dictation (it would send audio to the cloud), suggestions or
  swipe.
- The mic is on only while the button is red, and it stops when the keyboard hides.
- Audio is sent to OpenRouter when you finish speaking, as with the Mac's cloud setups. The phone
  keeps no recordings or history.

## Build and test

```sh
cd android
./gradlew testDebugUnitTest   # unit + UI tests (Robolectric); screenshots → app/build/screenshots/
./gradlew assembleDebug       # → app/build/outputs/apk/debug/app-debug.apk
python3 scripts/build-dicts.py  # rebuild the word lists from AOSP (pinned commits)
```

Needs JDK 17+ and the Android SDK (platform 36). The UI tests draw the real views and touch them
with `MotionEvent`s, typing into a real `EditText` through the same `InputConnection` the service
uses. The mic and OpenRouter are fakes.

## Check on a phone

Robolectric can't cover these, so test them on a device:

- [ ] Recording works from the keyboard on your Android version (a visible input method may use
      the mic; this is how voice keyboards work, but it's untested here).
- [ ] A real dictation types polished text, with a wait like the Mac's (Cloud Flash's transcript
      takes about 0.5 s there, before polish).
- [ ] Swipe accuracy with a real thumb (tests use generated paths: 94% first choice when sloppy).
- [ ] Enter in a multi-line field (chat apps) adds a new line; in a search field it searches.
- [ ] Delete in apps that read raw keys (Termux; email recipient chips).

## Word lists

From AOSP, Apache-2.0: `en.txt` (60k words) from LatinIME's `en_US_wordlist.combined`;
`zh.txt` (63k words with pinyin) from PinyinIME's `rawdict_utf16_65105_freq.txt`.
`android/scripts/build-dicts.py` rebuilds them from pinned commits.

## Install

1. Get `app-debug.apk`: from the **Android keyboard** workflow's artifact on GitHub (Actions →
   latest run → `dictation-keyboard`), or build it as above.
2. Open it on the phone and allow installing from that app when Android asks.
3. Open **Dictation Keyboard** from the launcher and follow its four steps: turn it on, switch to
   it, allow the microphone, paste an OpenRouter API key.

Builds are signed with the debug key of the machine that built them. An APK from a different
machine won't install over the current one: uninstall first (you'll paste the key again).
