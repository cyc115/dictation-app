#!/bin/zsh
# Publish a GitHub release of DictationApp.app, built from origin/main.
#
#   scripts/release.sh               # test, build, zip, tag v1.0.<commit count>, publish
#   scripts/release.sh --draft       # publish as a draft (review it on GitHub, then publish there)
#   scripts/release.sh --dry-run     # build, zip and sign the appcast only; prints where they are
#   scripts/release.sh --skip-tests  # don't run ./test.sh first
#
# The version matches build.sh (1.0.<commit count>), so the release and an app built from the
# same commit show the same version. Needs a clean tree on main, in sync with origin, and `gh`.
#
# Each release also carries appcast.xml, signed with the update key: installed apps read the latest
# release's (Info.plist's SUFeedURL) to find and check updates. The key's private half is
# ~/.config/dictation-app/sparkle-private-key (age-encrypted in chezmoi), or $SPARKLE_KEY_FILE.
set -euo pipefail
cd "$(dirname "$0")/.."

DRAFT=() DRY_RUN=false SKIP_TESTS=false
for arg in "$@"; do
  case "$arg" in
    --draft) DRAFT=(--draft) ;;
    --dry-run) DRY_RUN=true ;;
    --skip-tests) SKIP_TESTS=true ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg (see --help)" >&2; exit 2 ;;
  esac
done

fail() { echo "❌ $1" >&2; exit 1; }

SPARKLE_KEY="${SPARKLE_KEY_FILE:-$HOME/.config/dictation-app/sparkle-private-key}"
[[ -r "$SPARKLE_KEY" ]] || fail "no update key at $SPARKLE_KEY (chezmoi apply ~/.config/dictation-app)"

[[ -z "$(git status --porcelain --untracked-files=no)" ]] || fail "uncommitted changes; commit or stash them first"
[[ "$(git branch --show-current)" == main ]] || fail "not on main"
git fetch -q origin main
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "main isn't in sync with origin/main; pull or push first"

VERSION="1.0.$(git rev-list --count HEAD)"
TAG="v$VERSION"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "$TAG already exists; nothing new to release"
if ! $DRY_RUN && gh release view "$TAG" >/dev/null 2>&1; then fail "release $TAG already exists on GitHub"; fi

$SKIP_TESTS || ./test.sh

OUT=$(mktemp -d)
./build.sh --bundle "$OUT/DictationApp.app"
ZIP="$OUT/DictationApp-$VERSION.zip"
# ditto keeps the code signature and extended attributes, which `zip` drops.
ditto -c -k --keepParent "$OUT/DictationApp.app" "$ZIP"
echo "==> $ZIP ($(du -h "$ZIP" | cut -f1))"

PREV=$(git describe --tags --abbrev=0 2>/dev/null || true)
CHANGES=$([[ -n "$PREV" ]] && git log --no-merges --format='- %s' "$PREV..HEAD" || echo "First release.")

# The appcast: this release only, with its changes as the notes Sparkle shows. Its own folder, so
# generate_appcast sees just this zip.
FEED="$OUT/feed"
mkdir -p "$FEED"
cp "$ZIP" "$FEED/"
{ [[ -n "$PREV" ]] && echo "## Changes since $PREV" && echo; echo "$CHANGES"; } > "$FEED/DictationApp-$VERSION.md"
.build/artifacts/sparkle/Sparkle/bin/generate_appcast --ed-key-file - --embed-release-notes \
  --download-url-prefix "https://github.com/cyc115/dictation-app/releases/download/$TAG/" \
  --link "https://github.com/cyc115/dictation-app" "$FEED" < "$SPARKLE_KEY"
APPCAST="$FEED/appcast.xml"
grep -q 'sparkle:edSignature=' "$APPCAST" || fail "appcast.xml has no signature"
echo "==> $APPCAST"
$DRY_RUN && exit 0

NOTES="$OUT/notes.md"
{
  echo "## Install"
  echo
  echo "1. Download \`DictationApp-$VERSION.zip\`, unzip it, and move \`DictationApp.app\` to \`/Applications\`."
  echo "2. The app is signed with a self-signed certificate, not an Apple Developer ID, so macOS blocks"
  echo "   it the first time. Either run \`xattr -dr com.apple.quarantine /Applications/DictationApp.app\`,"
  echo "   or open it once, then System Settings → Privacy & Security → **Open Anyway**."
  echo "3. Grant Microphone, Speech Recognition and Accessibility, then relaunch the app."
  echo
  echo "Already have a version whose menu has **Check for Updates…**? Use that instead."
  echo
  echo "Needs macOS 26 or later on Apple silicon. See the [README](https://github.com/cyc115/dictation-app#readme)."
  echo
  [[ -n "$PREV" ]] && echo "## Changes since $PREV" && echo
  echo "$CHANGES"
} > "$NOTES"

git tag -a "$TAG" -m "DictationApp $VERSION"
git push -q origin "$TAG"
gh release create "$TAG" "$ZIP" "$APPCAST" --title "DictationApp $VERSION" --notes-file "$NOTES" --verify-tag "${DRAFT[@]}"
rm -rf "$OUT"
