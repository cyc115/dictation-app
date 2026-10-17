# Android keyboard: status and handoff (Oct 17, 2026)

Where the Android keyboard work stands, for the next session to pick up. Design and how-to:
[android-keyboard.md](android-keyboard.md).

## Where we are

- **Branch** `ccr-73a0bcbb-xkqmd3`, **draft PR [#2](https://github.com/cyc115/dictation-app/pull/2)** into
  `main`. CI (`.github/workflows/android.yml`, job `test-and-build`) is green on `192bb11`. No review
  comments yet. Not merged.
- **APK** `dictation-keyboard-0.1.0-debug.apk` (sha256 `9aa20438…7704`) was sent to Mike to sideload.
  Each CI run also uploads one as the `dictation-keyboard` artifact.
- **Not yet tested on a phone.** No real OpenRouter call has run either (no API key in the cloud container).
- **Next step for Mike:** install the APK, follow the app's four setup steps, and dictate and swipe for a day.
  Then report what's wrong: swipes that pick the wrong word (the word swiped and what came out), and
  anything from the device checklist in android-keyboard.md.

## What was built

- `android/`: a Kotlin input method (no AndroidX, no Compose), minSdk 29, targetSdk 36, AGP 8.13.2,
  Kotlin 2.3.21, Gradle 8.14.3 wrapper.
- **Dictation** (the default panel, Typeless-style): one tap to start, one to finish. It uses the Mac app's
  Cloud Flash (default) or Cloud Big setup, with the same models, backup model when slow, polish model,
  provider order, prompt v7, `<transcript>` tags, 0.8 s polish backup and 6 s polish deadline. **AI polish
  is on by default** (off on the Mac); the ✎ button toggles it. A mic key on the letter layouts dictates
  and then returns to the keys.
- **Keys:** a voice / EN / 拼 switch. English has tap, swipe, completions, swipe alternatives and
  auto-capitals. 拼音 has tap and swipe pinyin with candidates: a best-split sentence, exact
  spellings, completions and first syllables.
- **Shared with the Mac app:** the Gradle task `ExtractSpec` reads `DictationSetup.builtInJSON` and the
  `PolishPrompt` versions from `Sources/DictationKit/Setups.swift` at build time. The cloud logic is
  ported to Kotlin (`OpenRouter.kt`, `Race.kt`, `Dictation.kt`) with the Mac tests that cover it. No
  Swift changed.
- **Security:** the API key is AES-GCM sealed with an Android Keystore key and kept out of backups and
  device transfers. Password fields get no dictation, suggestions or swipe. The mic stops when the
  keyboard hides.
- **Word lists:** from AOSP, Apache-2.0 (LatinIME en_US, PinyinIME rawdict), rebuilt by
  `android/scripts/build-dicts.py` from pinned commits.

## Tests (58, all passing)

- Unit tests: ported Mac tests (requests, errors, backup race, adaptive spells, polish deadline,
  WAV), the spec check (extracted prompts equal `bench/polish_prompts/*.txt`), pinyin candidates.
- Swipe on the real word lists with generated paths: 98.3% top-1 when clean; 94.3% top-1 and 100%
  top-3 when sloppy; about 7 ms per decode. Real thumbs will score lower.
- 19 Robolectric UI tests: real views, MotionEvent taps and swipes, typing into a real `EditText`. They
  use a fake mic and a scripted OpenRouter, and write screenshots to `android/app/build/screenshots/`.
- `lintDebug`: 0 errors.

## Decisions

- **Sharing:** a shared spec plus ported logic, not Kotlin Multiplatform, Rust or a homelab gateway.
  Reasons are in android-keyboard.md. Follow-up: move the spec to `spec/*.json` loaded by both apps;
  do it on a Mac, where `./test.sh` can verify it.
- **Google's closed-source swipe library: not used.** Mike asked to bundle it in the APK. This
  session's safety checks blocked the work, in auto mode and in a later response, so none of it is in
  the repo. Options left: tune our decoder (`GestureDecoder.kt`) from Mike's real swipes, or
  use HeliBoard for swiping, where Mike loads the library himself.
- **Not ported:** on-device models, history, corrections and learned prompts (the phone always uses the
  built-in v7), insights, intelligent mic selection, type-as-you-speak.

## Open items

- [ ] On-device checks (list in android-keyboard.md): mic from the input method, real dictation latency,
      real swipe accuracy, Enter in chat apps, Delete in Termux and recipient chips.
- [ ] Tune swipe from real misses: `GestureDecoder` constants (`SIGMA_*`, `PRIOR_WEIGHT`,
      `MISSED_WEIGHT`), with a test per reported miss in `SwipeTest`.
- [ ] Stable signing: debug APKs from different machines can't update each other, so the app must be
      uninstalled first (the API key has to be pasted again). Fix: a release keystore as a GitHub secret
      and a signed CI build. Mike has to create the secret.
- [ ] Mark PR #2 ready for review and merge once it works on the phone.

## Working in a cloud container

None of this is committed. Each new container needs it again:

- **Android SDK:** download `commandlinetools-linux-16111833_latest.zip` from
  dl.google.com/android/repository into `/root/android-sdk/cmdline-tools/latest`, run
  `sdkmanager --licenses`, then `sdkmanager "platforms;android-36" "build-tools;36.0.0" "platform-tools"`.
  Put `sdk.dir=/root/android-sdk` in `android/local.properties` (gitignored).
- **Maven Central rate-limits the proxy (HTTP 429).** Add `~/.gradle/init.d/central-mirror.gradle.kts`,
  which puts `https://maven-central.storage-download.googleapis.com/maven2/` first in
  `pluginManagement` and `dependencyResolutionManagement` repositories.
- **Robolectric** downloads `org.robolectric:android-all-instrumented:16-robolectric-13921718-i7`
  (213 MB) at test time from the same rate-limited host. Prefetch the jar, pom and `.sha1` from the mirror
  into `~/.m2/repository/org/robolectric/android-all-instrumented/16-robolectric-13921718-i7/`.
- No KVM, so no emulator. UI testing is Robolectric only.
- Then: `cd android && ./gradlew testDebugUnitTest assembleDebug lintDebug`.
