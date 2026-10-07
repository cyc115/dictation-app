#!/bin/zsh
# Build, install, and (re)launch DictationApp:  ./build.sh
# Quits any running copy first, so it's safe to run after every change.
set -euo pipefail
cd "$(dirname "$0")"

APP="/Applications/DictationApp.app"

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
swiftc -swift-version 5 -O -o /tmp/DictationApp-bin \
  Sources/main.swift \
  Sources/HotkeyManager.swift \
  Sources/SpeechEngine.swift \
  Sources/TextInjector.swift \
  Sources/OverlayWindow.swift \
  Sources/PolishService.swift \
  -framework AppKit \
  -framework AVFoundation \
  -framework Speech \
  -framework ApplicationServices \
  -Xlinker -weak_framework -Xlinker FoundationModels

echo "==> Quitting running DictationApp (if any)…"
pkill -x DictationApp || true
for _ in {1..20}; do pgrep -x DictationApp >/dev/null || break; sleep 0.1; done
pkill -9 -x DictationApp || true

echo "==> Bundling into $APP …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp /tmp/DictationApp-bin "$APP/Contents/MacOS/DictationApp"
cp Info.plist "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/DictationApp"

echo "==> Signing with stable local identity…"
ensure_signing_identity
security unlock-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN"
codesign --force --deep --keychain "$KEYCHAIN" --sign "$SIGN_ID" "$APP"

echo "==> Launching…"
open "$APP"
echo ""
echo "Grant the 3 permissions when prompted:"
echo "  1. Microphone (system prompt)"
echo "  2. Speech Recognition (system prompt)"
echo "  3. Accessibility: System Settings → Privacy & Security → Accessibility → enable DictationApp"
echo "Then relaunch the app and hold the hotkey (default Fn; change it in the menu bar) to dictate."
