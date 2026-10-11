#!/bin/zsh
# End-to-end speech check: synthesizes a long dictation with pauses (macOS `say`), runs it
# through the installed app's real recognition pipeline, and checks nothing was dropped.
#
#   scripts/e2e-speech.sh          # run the check (needs ./build.sh first; ~30 s)
#   scripts/e2e-speech.sh --log    # also print the app's result line
#
# Exits 1 if any part of the dictation is missing from the final transcript.
set -euo pipefail
APP="/Applications/DictationApp.app"
SHOW_LOG=0
for arg in "$@"; do
  case "$arg" in
    --log) SHOW_LOG=1 ;;
    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg (see --help)" >&2; exit 2 ;;
  esac
done
[[ -d "$APP" ]] || { echo "not found: $APP — run ./build.sh first" >&2; exit 2; }

DIR="$(mktemp -d -t dictationapp-e2e)"
trap 'rm -rf "$DIR"' EXIT
say -o "$DIR/speech.aiff" "This is the first part of a long dictation about the new settings page. [[slnc 2500]] Here is the second part, after a short pause, about the history window. [[slnc 4000]] And this is the third part, after a longer pause, about the app icon. [[slnc 2500]] Finally the fourth part wraps everything up."

was_running=0; pgrep -x DictationApp >/dev/null && was_running=1
pkill -x DictationApp 2>/dev/null || true
sleep 0.5
# One on-device dictation through the app's latency probe (LatencyProbe.swift), at real-time pace.
cat > "$DIR/plan.json" <<JSON
{"pause": 0, "timeout": 60, "trials": [{"id": "e2e", "file": "$DIR/speech.aiff", "stt": "apple:en-US", "polish": []}]}
JSON
open -n --env "DICTATIONAPP_LATENCY_PLAN=$DIR/plan.json" --env "DICTATIONAPP_LATENCY_OUT=$DIR/out.jsonl" "$APP"
for _ in {1..120}; do [[ -s "$DIR/out.jsonl" ]] && break; sleep 1; done
(( was_running )) && open "$APP"

(( SHOW_LOG )) && cat "$DIR/out.jsonl"
field() { /usr/bin/python3 -c 'import json,sys; r=json.loads(open(sys.argv[1]).readline()); v=r.get(sys.argv[2]); print(len(v or []) if sys.argv[3:] else "".join(v) if isinstance(v, list) else v or "")' "$DIR/out.jsonl" "$@" 2>/dev/null || true; }
final=$(field raw)
[[ -n "$final" ]] || { echo "❌ no final transcript"; cat "$DIR/out.jsonl" 2>/dev/null; exit 1; }
echo "transcript: $final"
missing=()
for phrase in "first part" "settings page" "second part" "history window" "third part" "app icon" "fourth part" "everything up"; do
  [[ "${final:l}" == *"$phrase"* ]] || missing+=("$phrase")
done
if (( ${#missing} )); then
  echo "❌ missing: ${(j:, :)missing}"
  exit 1
fi
echo "✅ all 4 parts of the dictation kept"

# Streaming mode types each finished utterance as it happens, then the rest at stop; check
# the streamed pieces add up to exactly the final transcript (nothing doubled or lost).
streamed=$(field utterances)
utterances=$(field utterances count)
if [[ "$final" != "$streamed"* ]]; then
  echo "❌ streamed text is not a prefix of the final transcript"
  echo "   streamed: $streamed"
  exit 1
fi
(( utterances >= 3 )) || { echo "❌ only $utterances utterance(s) streamed; expected one per pause"; exit 1; }
echo "✅ streamed $utterances utterances as they finished, matching the final transcript"
