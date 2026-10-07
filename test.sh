#!/bin/zsh
# Run the test suite: unit, UI (accessibility-driven), visual snapshots and performance budgets.
#
#   ./test.sh                 # all tests
#   ./test.sh --filter Hotkey # subset (passed through to `swift test`)
#   ./test.sh --perf          # also run the app-level perf check (relaunches the installed app)
#   ./test.sh --live          # also hit the real OpenRouter API through CloudEngine (needs $OPENROUTER_KEY, ~$0.001)
#   RECORD_SNAPSHOTS=1 ./test.sh --filter SnapshotTests   # re-record reference images after a UI change
set -euo pipefail
cd "$(dirname "$0")"

PERF=0
LIVE=0
args=()
for arg in "$@"; do
  case "$arg" in
    --perf) PERF=1 ;;
    --live) LIVE=1 ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) args+=("$arg") ;;
  esac
done

(( LIVE )) && export LIVE_OPENROUTER=1
swift test "${args[@]}" 2>&1 | tee "${TMPDIR:-/tmp}/dictationapp-test.log" | grep -E "error:|failed|Executed .* tests|\[perf\]" || true
if grep -qE "error:|with [1-9][0-9]* failures?" "${TMPDIR:-/tmp}/dictationapp-test.log"; then
  echo "❌ tests failed (full log: ${TMPDIR:-/tmp}/dictationapp-test.log)"
  exit 1
fi
echo "✅ tests passed"

if (( PERF )); then
  scripts/perf.sh
fi
