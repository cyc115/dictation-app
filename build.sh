#!/bin/zsh
# Build + install DictationApp on your Mac. Run once:  zsh ~/DictationApp/build.sh
set -euo pipefail
cd "$(dirname "$0")"

APP="$HOME/Applications/DictationApp.app"

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

echo "==> Bundling into $APP …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp /tmp/DictationApp-bin "$APP/Contents/MacOS/DictationApp"
cp Info.plist "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/DictationApp"

echo "==> Ad-hoc signing…"
codesign --force --deep --sign - "$APP"

echo "==> Launching…"
open "$APP"
echo ""
echo "Grant the 3 permissions when prompted:"
echo "  1. Microphone (system prompt)"
echo "  2. Speech Recognition (system prompt)"
echo "  3. Accessibility: System Settings → Privacy & Security → Accessibility → enable DictationApp"
echo "Then relaunch the app and hold Fn to dictate."
