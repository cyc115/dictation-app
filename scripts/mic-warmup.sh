#!/bin/zsh
# Mic warm-up: how long a mic takes to send real audio after it's opened, through the installed
# app's real MicCapture (so the app's microphone permission applies). Bluetooth headsets send
# silence for a while as they switch into call mode; the pill shows that wait.
#
#   scripts/mic-warmup.sh                      # the app's mic (Settings), or the system default
#   scripts/mic-warmup.sh --uid <uid>          # one mic, by CoreAudio UID
#   scripts/mic-warmup.sh --runs 3 --seconds 4 # repeat; seconds each mic stays open
#   scripts/mic-warmup.sh --backups            # other wired/built-in mics record too; speak to see a switch
#   scripts/mic-warmup.sh --json               # raw result lines
#
# Opening a Bluetooth mic switches the headset into call mode (lower audio quality) while it runs.
set -euo pipefail
APP="/Applications/DictationApp.app"
UID_ARG="" RUNS=1 SECONDS_OPEN=4 BACKUPS=0 JSON=0
while (( $# )); do
  case "$1" in
    --uid) UID_ARG="${2:?--uid needs a value}"; shift ;;
    --runs) RUNS="${2:?--runs needs a value}"; shift ;;
    --seconds) SECONDS_OPEN="${2:?--seconds needs a value}"; shift ;;
    --backups) BACKUPS=1 ;;
    --json) JSON=1 ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done
[[ -d "$APP" ]] || { echo "not found: $APP — run ./build.sh first" >&2; exit 2; }
[[ -n "$UID_ARG" ]] || UID_ARG="$(defaults read com.mikechen.DictationApp microphoneUID 2>/dev/null || true)"

DIR="$(mktemp -d -t dictationapp-mic)"
trap 'rm -rf "$DIR"' EXIT
for run in $(seq 1 "$RUNS"); do
  out="$DIR/$run.json"
  open -n --env "DICTATIONAPP_MIC_PROBE_OUT=$out" --env "DICTATIONAPP_MIC_PROBE_UID=$UID_ARG" \
       --env "DICTATIONAPP_MIC_PROBE_SECONDS=$SECONDS_OPEN" --env "DICTATIONAPP_MIC_PROBE_BACKUPS=$BACKUPS" "$APP"
  for _ in $(seq 1 $(( SECONDS_OPEN * 4 + 40 ))); do [[ -s "$out" ]] && break; sleep 0.25; done
  [[ -s "$out" ]] || { echo "run $run: no result (did the app open?)" >&2; exit 1; }
  if (( JSON )); then cat "$out"; else
    /usr/bin/python3 -c '
import json, sys
r = json.load(open(sys.argv[1]))
fmt = lambda v: "never" if v is None else "%d ms" % v
line = "run %s: %s" % (sys.argv[2], r.get("device"))
if r.get("bluetooth"): line += " (Bluetooth)"
line += ": first audio %s, live %s" % (fmt(r.get("firstBuffer")), fmt(r.get("live")))
if r.get("noAudioAt"): line += ", no audio at %d ms" % r["noAudioAt"]
if len(r.get("mics") or []) > 1: line += ", mics open: " + ", ".join(r["mics"])
if r.get("switchedTo"): line += ", switched to %s at %d ms" % (r["switchedTo"], r["switchedAt"])
if r.get("error"): line += ", error: " + r["error"]
print(line)' "$out" "$run"
  fi
  if (( run < RUNS )); then sleep 1.5; fi
done
