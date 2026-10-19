#!/bin/zsh
# Build, install, and (re)launch DictationApp:  ./build.sh
# Quits any running copy first, so it's safe to run after every change.
#   ./build.sh --keep-running   installs without quitting the running copy, so a dictation
#                               in progress isn't cut off; the app relaunches into the new build
#                               once it's idle (AppRelaunch: a replaced copy loses the microphone).
#   ./build.sh --bundle <path.app>  only builds and signs the app at <path.app>; nothing is
#                               installed or quit (scripts/release.sh uses it).
set -euo pipefail
cd "$(dirname "$0")"

KEEP_RUNNING=false
BUNDLE_ONLY=""
case "${1:-}" in
  --keep-running) KEEP_RUNNING=true ;;
  --bundle) BUNDLE_ONLY="${2:?usage: ./build.sh --bundle <path.app>}" ;;
esac

INSTALLED="/Applications/DictationApp.app"
# Bundled and signed beside the installed copy, then swapped in with a rename (same volume).
APP="${BUNDLE_ONLY:-/Applications/.DictationApp-new.app}"

# Signing: a self-signed cert kept in its own keychain. Because the cert stays the
# same across builds, macOS keeps the Accessibility/Microphone grants after a rebuild
# (ad-hoc signatures change every build and silently invalidate them).
# The keychain only holds this throwaway local cert, so its password isn't a secret.
SIGN_ID="DictationApp Local Signing"
KEYCHAIN="$HOME/Library/Keychains/dictationapp-signing.keychain-db"
KEYCHAIN_PW="dictationapp-local"

ensure_signing_identity() {
  [[ -f "$KEYCHAIN" ]] && security find-certificate -c "$SIGN_ID" "$KEYCHAIN" >/dev/null 2>&1 && return
  echo "    creating self-signed code-signing cert '$SIGN_ID' (one time)…"
  local tmp; tmp=$(mktemp -d)
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -subj "/CN=$SIGN_ID" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
  openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -out "$tmp/id.p12" \
    -passout pass:"$KEYCHAIN_PW" -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1
  [[ -f "$KEYCHAIN" ]] || security create-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN"
  security set-keychain-settings "$KEYCHAIN"   # never auto-lock
  security unlock-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN"
  security import "$tmp/id.p12" -k "$KEYCHAIN" -P "$KEYCHAIN_PW" -T /usr/bin/codesign
  security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PW" "$KEYCHAIN" >/dev/null
  rm -rf "$tmp"
}

echo "==> Compiling…"
swift build -c release --product DictationApp
BIN="$(swift build -c release --show-bin-path)/DictationApp"

echo "==> Bundling…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/DictationApp"
cp Info.plist "$APP/Contents/Info.plist"
# Version: 1.0.<commit count>, "-dev" if the tree has uncommitted changes; build = commit.
COUNT=$(git rev-list --count HEAD 2>/dev/null || echo 0)
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
VERSION="1.0.$COUNT"
[[ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]] && VERSION="$VERSION-dev"
PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $COMMIT" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :DictationBuildDate string $(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PLIST"
echo "    version $VERSION ($COMMIT)"
mkdir -p "$APP/Contents/Resources"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # regenerate: swift scripts/make-icon.swift
# Libraries' resources, e.g. MLX's compiled GPU code (the on-device speech model can't run without
# it): each library's Bundle.module looks for its bundle in Contents/Resources first.
cp -R "$(dirname "$BIN")"/*.bundle "$APP/Contents/Resources/"
cp bench/polish_cases.json bench/polish_cases_holdout.json "$APP/Contents/Resources/"   # the guard when learning a prompt
chmod +x "$APP/Contents/MacOS/DictationApp"

echo "==> Signing with stable local identity…"
ensure_signing_identity
security unlock-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN"
codesign --force --deep --keychain "$KEYCHAIN" --sign "$SIGN_ID" "$APP"

if [[ -n "$BUNDLE_ONLY" ]]; then
  echo "==> Built $APP"
  exit 0
fi

# A running copy keeps running from the old files, but macOS revokes its microphone access once
# they're replaced, so it watches for this swap and relaunches itself when no dictation is running.
swap_in() {
  local old="/Applications/.DictationApp-old-$$.app"
  [[ -d "$INSTALLED" ]] && mv "$INSTALLED" "$old"
  mv "$APP" "$INSTALLED"
  rm -rf "$old"
}

if $KEEP_RUNNING && pgrep -x DictationApp >/dev/null; then
  echo "==> Installing to $INSTALLED (the running copy keeps going; quit and reopen it for this build)…"
  swap_in
  exit 0
fi

echo "==> Quitting running DictationApp (if any)…"
pkill -x DictationApp || true
for _ in {1..20}; do pgrep -x DictationApp >/dev/null || break; sleep 0.1; done
pkill -9 -x DictationApp || true

echo "==> Installing to $INSTALLED and launching…"
swap_in
open "$INSTALLED"
echo ""
echo "Grant the 3 permissions when prompted:"
echo "  1. Microphone (system prompt)"
echo "  2. Speech Recognition (system prompt)"
echo "  3. Accessibility: System Settings → Privacy & Security → Accessibility → enable DictationApp"
echo "Then relaunch the app and hold the hotkey (default Fn; change it in the menu bar) to dictate."
