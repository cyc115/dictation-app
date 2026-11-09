#!/bin/sh
# Swaps a new build in for the installed one:  scripts/swap-in.sh <new.app> <installed.app>
# Both on the same volume, so each step is a rename. A running copy keeps running from the old
# files, but macOS revokes its microphone access once they're replaced, so it watches for this
# swap (BundleWatcher) and relaunches itself when no dictation is running (AppRelaunch).
# If the new build can't be moved in, the installed one is put back. BundleWatcherTests runs this very script.
set -eu
new="$1" installed="$2"
old="$(dirname "$installed")/.$(basename "$installed" .app)-old-$$.app"
if [ -d "$installed" ]; then mv "$installed" "$old"; fi
if ! mv "$new" "$installed"; then
  if [ -d "$old" ]; then mv "$old" "$installed"; fi
  exit 1
fi
rm -rf "$old"
