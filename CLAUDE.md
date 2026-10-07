# DictationApp

macOS menu-bar dictation app (Swift, no Xcode project). Build with `./build.sh`.

## Workflow
- After every major feature change: run `./build.sh`. It compiles, quits the running copy, installs to `/Applications/DictationApp.app`, and launches the new build, so the user can try it right away. Do it once the change compiles; don't ask first.
- Builds are signed with a stable self-signed cert ("DictationApp Local Signing", in `~/Library/Keychains/dictationapp-signing.keychain-db`, created by `build.sh` on first run), so permissions survive rebuilds. Don't switch back to ad-hoc signing (`--sign -`): it changes the signature each build and silently voids the Accessibility grant.
