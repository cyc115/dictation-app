# DictationApp

macOS menu-bar dictation app (Swift, no Xcode project). Build with `./build.sh`.

## Workflow
- After every major feature change: run `./build.sh`. It compiles, quits the running copy, installs to `~/Applications/DictationApp.app`, and launches the new build, so the user can try it right away. Do it once the change compiles; don't ask first.
- Builds are ad-hoc signed, so macOS may drop the Accessibility permission after a rebuild. Remind the user to re-enable it in System Settings → Privacy & Security → Accessibility if the hotkey stops working.
