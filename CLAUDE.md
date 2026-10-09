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
- App-level perf (launch time, idle CPU, memory): `scripts/perf.sh` (also `./test.sh --perf`). Run it after changes to launch, audio or anything that runs in the background.
- Minor changes (copy/text tweaks, small fixes): commit and push, but don't rebuild or relaunch — it interrupts the user. They'll ship with the next major build.
- After every major feature change: run `./build.sh`. It compiles, quits the running copy, installs to `/Applications/DictationApp.app`, and launches the new build, so the user can try it right away. Do it once the change compiles; don't ask first.
- Builds are signed with a stable self-signed cert ("DictationApp Local Signing", in `~/Library/Keychains/dictationapp-signing.keychain-db`, created by `build.sh` on first run), so permissions survive rebuilds. Don't switch back to ad-hoc signing (`--sign -`): it changes the signature each build and silently voids the Accessibility grant.
