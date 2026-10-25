#!/bin/zsh
# Run the test suite: unit, UI (accessibility-driven), visual snapshots and performance budgets.
#
#   ./test.sh                 # all tests
#   ./test.sh --filter Hotkey # subset (passed through to `swift test`)
#   ./test.sh --perf          # also run the app-level perf check (relaunches the installed app)
#   ./test.sh --live          # also hit the real OpenRouter API through CloudEngine (needs $OPENROUTER_API_KEY, ~$0.001)
#   ./test.sh --local         # also run the real on-device model through LocalEngine (first run downloads 2.5 GB)
#   RECORD_SNAPSHOTS=1 ./test.sh --filter SnapshotTests   # re-record reference images after a UI change
set -euo pipefail
cd "$(dirname "$0")"

PERF=0
LIVE=0
LOCAL=0
args=()
for arg in "$@"; do
  case "$arg" in
    --perf) PERF=1 ;;
    --live) LIVE=1 ;;
    --local) LOCAL=1 ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) args+=("$arg") ;;
  esac
done

(( LIVE )) && export LIVE_OPENROUTER=1
(( LOCAL )) && export LIVE_LOCAL_MODEL=1
LOG="${TMPDIR:-/tmp}/dictationapp-test.log"
swift test "${args[@]}" 2>&1 | tee "$LOG" | grep -E "error:|failed|Executed .* tests|\[perf\]|\[local\]" || true
# A compile error or failed assertion; not a SwiftPM warning that mentions one ("warning: …: skipping
# cache due to an error: …", printed by a fresh clone's first resolve).
if grep -vE "^warning:" "$LOG" | grep -qE "error:|with [1-9][0-9]* failures?"; then
  echo "❌ tests failed (full log: $LOG)"
  exit 1
fi
# A message logged over and over (once per pixel, per buffer…) slows the tests and fills the disk:
# the snapshot diff once logged "Unrecognized colorspace" 8.8M times a run. Fail on any repeated
# 1000+ times (timestamps and process ids removed first).
spam=$(sed -E 's/^[0-9-]+ [0-9:.]+ [^ ]+\[[0-9:]+\] //' "$LOG" | sort | uniq -c | sort -rn | awk '$1 >= 1000' | head -3)
if [[ -n "$spam" ]]; then
  echo "❌ the tests logged the same line 1000+ times; stop whatever logs it:"
  echo "$spam"
  exit 1
fi
echo "✅ tests passed"

if (( PERF )); then
  scripts/perf.sh
fi
