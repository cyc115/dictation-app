# DictationApp

macOS menu-bar dictation app. Swift package: `Sources/DictationKit` (all app code), `Sources/DictationApp` (entry point), `Tests/DictationKitTests`.

## Workflow
- Before building or committing: `./test.sh` (unit, UI, snapshot and perf-budget tests). Every new feature or fix gets tests in the same change:
  - logic → unit tests with injected `UserDefaults` / file URLs / pasteboards (see `TestSupport.swift`), never the user's real ones;
  - UI → `HostedView` + accessibility identifiers (`.accessibilityIdentifier`), driven with `click(_:)`; add a snapshot for new visual surfaces;
  - hot paths (audio thread, overlay, history I/O) → an `assertFaster` budget in `PerformanceTests.swift`.
- Cloud transcription changes: also run `./test.sh --live` (real API, both cloud models). Live and integration tests must exercise the app's real code path (e.g. `CloudEngine.stop()`), not a test-only helper — a helper hid the unfinished-WAV bug that only the real path had.
- Intentional UI change: `RECORD_SNAPSHOTS=1 ./test.sh --filter SnapshotTests`, then look at the new PNGs in `Tests/DictationKitTests/__Snapshots__/` before committing.
- Dictation turnaround (stop → text, per speech/polish model): `bench/suite.py latency run` (drives the installed app; see `bench/README.md`). Run it after changes to `CloudEngine`, `SpeechEngine.stop` or polish.
- AI polish model or prompt changes: `bench/suite.py polish run` (quality on tricky dictations + wait; see `bench/results/polish/README.md`). Setups (speech + polish model + prompt) are in `Sources/DictationKit/Setups.swift`; keep each `PolishPrompt` version identical to `bench/polish_prompts/<version>.txt` (a bench test checks), and add a new version rather than editing one a setup uses.
- App-level perf (launch time, idle CPU, memory): `scripts/perf.sh` (also `./test.sh --perf`). Run it after changes to launch, audio or anything that runs in the background.
- Minor changes (copy/text tweaks, small fixes): commit and push, but don't rebuild or relaunch — it interrupts the user. They'll ship with the next major build.
- After every major feature change: run `./build.sh --keep-running`. It compiles and installs to `/Applications/DictationApp.app` without quitting the running copy, so a dictation in progress is never cut off; the user gets the new build next time they reopen the app. Do it once the change compiles; don't ask first. Plain `./build.sh` (quits and relaunches) only when the user asks for a restart.
- Builds are signed with a stable self-signed cert ("DictationApp Local Signing", in `~/Library/Keychains/dictationapp-signing.keychain-db`, created by `build.sh` on first run), so permissions survive rebuilds. Don't switch back to ad-hoc signing (`--sign -`): it changes the signature each build and silently voids the Accessibility grant.
- The cloud API key lives in `~/Library/Application Support/DictationApp/secrets.json` (0600, folder 0700; `FileSecretStore`), not the Keychain: with no Apple team ID the Keychain treats every build as a new app and asks for the login password again. Don't move it back unless builds get a Developer ID.
