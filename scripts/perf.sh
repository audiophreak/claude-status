#!/usr/bin/env bash
# Reproducible performance measurements against an ISOLATED instance (temporary
# CLAUDE_STATUS_HOME; the real state, settings and installed app are not touched):
#   hook latency (process start to exit, N runs), event-to-indicator latency (hook run to the
#   app's published state), app startup to first published state, idle CPU and memory of the
#   app with M sessions over a window, bundle size, bytes per session record.
# usage: scripts/perf.sh [--runs 200] [--sessions 50] [--idle-seconds 120] [--bundle PATH.app]
#        (--bundle measures another build, e.g. a previous release, the same way)
source "$(dirname "$0")/lib.sh"
cd "$REPO_ROOT" || exit 1
RUNS=200 SESSIONS=50 IDLE=120
while [[ $# -gt 0 ]]; do
  case "$1" in
    --runs) RUNS="$2"; shift 2 ;;
    --sessions) SESSIONS="$2"; shift 2 ;;
    --idle-seconds) IDLE="$2"; shift 2 ;;
    --bundle) APP_BUNDLE="$2"; shift 2 ;;
    *) die "unknown option $1" ;;
  esac
done
[[ -d "$APP_BUNDLE" ]] || "$REPO_ROOT/scripts/build.sh" >/dev/null
HOOK="$APP_BUNDLE/Contents/Helpers/claude-status-hook"
APPBIN="$APP_BUNDLE/Contents/MacOS/ClaudeStatus"
W="$(mktemp -d "${TMPDIR:-/tmp}/claude-status-perf.XXXXXX")"
APP_PID=""
cleanup() {
  [[ -n "$APP_PID" ]] && kill "$APP_PID" 2>/dev/null
  case "$W" in "${TMPDIR:-/tmp}"/claude-status-perf.*) rm -r "$W" ;; esac
}
trap cleanup EXIT
H="$W/home"; DUMP="$H/dump.json"; mkdir -p "$H"

python3 - "$HOOK" "$H" "$RUNS" <<'PY'
import json, os, subprocess, sys, time, statistics
hook, home, runs = sys.argv[1], sys.argv[2], int(sys.argv[3])
env = {"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin", "CLAUDE_STATUS_HOME": home}
names = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"]
lat = []
for i in range(runs):
    ev = {"session_id": "perf-%d" % (i % 10), "hook_event_name": names[i % 4], "cwd": "/tmp", "tool_name": "Bash",
          "tool_use_id": "t%d" % (i // 4), "background_tasks": [], "session_crons": [], "tool_input": {"command": "x" * 2000}}
    data = json.dumps(ev).encode()
    t = time.perf_counter()
    subprocess.run([hook], input=data, env=env, check=False)
    lat.append((time.perf_counter() - t) * 1000)
lat.sort()
print("hook latency (process spawn to exit, %d runs): median %.1f ms, p95 %.1f ms, max %.1f ms" %
      (runs, statistics.median(lat), lat[int(len(lat) * 0.95) - 1], lat[-1]))
PY
sizes=$(find "$H/sessions" -name '*.json' -exec stat -f %z {} + | sort -n)
echo "session record size: $(echo "$sizes" | head -1)–$(echo "$sizes" | tail -1) bytes"

# Seed sessions, then start the app and time the first published state.
for i in $(seq 1 "$SESSIONS"); do
  printf '{"session_id":"seed-%d","hook_event_name":"Stop","cwd":"/tmp","background_tasks":[]}' "$i" \
    | CLAUDE_STATUS_HOME="$H" "$HOOK"
done
T0=$(python3 -c 'import time; print(time.time())')
CLAUDE_STATUS_HOME="$H" CLAUDE_STATUS_STATE_DUMP="$DUMP" "$APPBIN" >/dev/null 2>&1 &
APP_PID=$!
for _ in $(seq 1 400); do [[ -f "$DUMP" ]] && break; sleep 0.01; done
python3 -c "import time; print('app startup to first published state (%d sessions): %.0f ms' % ($SESSIONS, (time.time() - $T0) * 1000))"
sleep 2

python3 - "$HOOK" "$H" "$DUMP" <<'PY'
import json, os, subprocess, sys, time, statistics
hook, home, dump = sys.argv[1:4]
env = {"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin", "CLAUDE_STATUS_HOME": home}
lat = []
for i in range(20):
    ev = "UserPromptSubmit" if i % 2 == 0 else "Stop"
    want = "working" if ev == "UserPromptSubmit" else "complete"
    t = time.perf_counter()
    subprocess.run([hook], input=json.dumps({"session_id": "lat", "hook_event_name": ev, "background_tasks": []}).encode(), env=env)
    while time.perf_counter() - t < 5:
        try:
            d = json.load(open(dump))
            if any(s["id"] == "lat" and s["state"] == want for s in d["sessions"]): break
        except Exception:
            pass
        time.sleep(0.005)
    lat.append((time.perf_counter() - t) * 1000)
    time.sleep(0.3)
lat.sort()
print("event-to-indicator latency (hook start to app state, 20 events): median %.0f ms, max %.0f ms" % (statistics.median(lat), lat[-1]))
PY

cpu0=$(ps -o time= -p "$APP_PID" | awk -F'[:.]' '{print ($1*60+$2)+$3/100}')
sleep "$IDLE"
cpu1=$(ps -o time= -p "$APP_PID" | awk -F'[:.]' '{print ($1*60+$2)+$3/100}')
python3 -c "print('app idle CPU over %ds with %d sessions: %.3f %%' % ($IDLE, $SESSIONS, ($cpu1 - $cpu0) / $IDLE * 100))"
footprint "$APP_PID" 2>/dev/null | awk '/Footprint:/ {for (i = 1; i < NF; i++) if ($i == "Footprint:") {print "app memory footprint (phys_footprint): " $(i+1) " " $(i+2); exit}}'
ps -o rss= -p "$APP_PID" | awk '{printf "app resident memory (RSS): %.1f MB\n", $1/1024}'
echo "bundle size: $(du -sk "$APP_BUNDLE" | cut -f1) KB; hook binary $(stat -f %z "$HOOK") bytes; arch $(lipo -archs "$APPBIN")"
