#!/bin/zsh
# App-level performance check for the installed DictationApp:
# launch time, idle CPU and memory. Exits 1 if any budget is exceeded.
#
#   scripts/perf.sh            # human-readable table
#   scripts/perf.sh --json     # machine-readable
#   scripts/perf.sh --help
#
# Relaunches /Applications/DictationApp.app (run ./build.sh first). Leaves it running.
set -euo pipefail
zmodload zsh/datetime

APP="/Applications/DictationApp.app"
SAMPLE_SECONDS=10
LAUNCH_BUDGET_MS=1500   # process start → applicationDidFinishLaunching done
IDLE_CPU_BUDGET=1.0     # average % of one core while idle
RSS_BUDGET_MB=150       # resident memory while idle
JSON=0

for arg in "$@"; do
  case "$arg" in
    --json) JSON=1 ;;
    --app=*) APP="${arg#--app=}" ;;
    --seconds=*) SAMPLE_SECONDS="${arg#--seconds=}" ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg (see --help)" >&2; exit 2 ;;
  esac
done
[[ -d "$APP" ]] || { echo "not found: $APP — run ./build.sh first" >&2; exit 2; }

log() { (( JSON )) || echo "$@"; }

pkill -x DictationApp 2>/dev/null || true
for _ in {1..30}; do pgrep -x DictationApp >/dev/null || break; sleep 0.1; done

READY="$(mktemp -t dictationapp-ready)"; rm -f "$READY"
log "==> Launching $APP"
start=$EPOCHREALTIME
open -n --env "DICTATIONAPP_READY_FILE=$READY" "$APP"
for _ in {1..100}; do [[ -s "$READY" ]] && break; sleep 0.05; done
[[ -s "$READY" ]] || { echo "app did not finish launching within 5s" >&2; exit 1; }
launch_ms=$(( ($(<"$READY") - start) * 1000 ))
rm -f "$READY"
pid=$(pgrep -x DictationApp | head -1)

log "==> Sampling idle CPU and memory for ${SAMPLE_SECONDS}s (pid $pid)"
sleep 2  # let launch work settle
cpu_total=0; rss_max=0
for _ in $(seq 1 "$SAMPLE_SECONDS"); do
  read -r cpu rss <<<"$(ps -o %cpu=,rss= -p "$pid")"
  cpu_total=$(( cpu_total + cpu ))
  (( rss > rss_max )) && rss_max=$rss
  sleep 1
done
cpu_avg=$(( cpu_total / SAMPLE_SECONDS ))
rss_mb=$(( rss_max / 1024.0 ))

fail=0
check() { (( $1 <= $2 )) && echo pass || { fail=1; echo FAIL; } }
launch_status=$(check "$launch_ms" "$LAUNCH_BUDGET_MS")
cpu_status=$(check "$cpu_avg" "$IDLE_CPU_BUDGET")
rss_status=$(check "$rss_mb" "$RSS_BUDGET_MB")
[[ "$launch_status$cpu_status$rss_status" == *FAIL* ]] && fail=1

if (( JSON )); then
  printf '{"launch_ms":%.0f,"idle_cpu_percent":%.2f,"rss_mb":%.1f,"budgets":{"launch_ms":%d,"idle_cpu_percent":%.1f,"rss_mb":%d},"pass":%s}\n' \
    "$launch_ms" "$cpu_avg" "$rss_mb" "$LAUNCH_BUDGET_MS" "$IDLE_CPU_BUDGET" "$RSS_BUDGET_MB" "$( (( fail )) && echo false || echo true)"
else
  printf '\n%-22s %10s %10s  %s\n' "metric" "value" "budget" "result"
  printf '%-22s %8.0f ms %7d ms  %s\n' "launch time" "$launch_ms" "$LAUNCH_BUDGET_MS" "$launch_status"
  printf '%-22s %9.2f %% %8.1f %%  %s\n' "idle CPU (avg)" "$cpu_avg" "$IDLE_CPU_BUDGET" "$cpu_status"
  printf '%-22s %8.1f MB %7d MB  %s\n' "memory (max RSS)" "$rss_mb" "$RSS_BUDGET_MB" "$rss_status"
fi
exit $fail
