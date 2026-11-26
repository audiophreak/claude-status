#!/usr/bin/env bash
# Integration tests against the real executables, using only temporary fixture directories.
# The real ~/.claude/settings.json is only ever READ (copied into a fixture), never written.
source "$(dirname "$0")/lib.sh"
set +e   # individual checks record failures; the script must not stop at the first one
cd "$REPO_ROOT" || exit 1

[[ -d "$APP_BUNDLE" ]] || "$REPO_ROOT/scripts/build.sh" >/dev/null
HOOK="$APP_BUNDLE/Contents/Helpers/claude-status-hook"
CTL="$APP_BUNDLE/Contents/Helpers/claude-status-ctl"
APPBIN="$APP_BUNDLE/Contents/MacOS/ClaudeStatus"
FIX="$REPO_ROOT/Tests/Fixtures/settings"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-status-it.XXXXXX")"
PASS=0 FAIL=0
APP_PIDS=()
cleanup() {
  for p in "${APP_PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done
  chmod -R u+w "$WORK" 2>/dev/null || true
  case "$WORK" in "${TMPDIR:-/tmp}"/claude-status-it.*) rm -r "$WORK" ;; esac
}
trap cleanup EXIT

ok()   { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

# Run the hook exactly as Claude Code would (stdin JSON), with a clean environment.
hook() { # home json
  env -i HOME="$HOME" PATH=/usr/bin:/bin CLAUDE_STATUS_HOME="$1" "$HOOK" <<<"$2"
}
state_of() { # home sid
  /usr/bin/plutil -extract state raw -o - "$1/sessions/$2.json" 2>/dev/null || echo none
}
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

echo "Hook executable"
H="$WORK/h1"
out="$(hook "$H" '{"session_id":"it-1","hook_event_name":"UserPromptSubmit","cwd":"/tmp","prompt":"TOPSECRET"}')"; rc=$?
check "valid event exits 0 with no stdout" test "$rc" = 0 -a -z "$out"
check "valid event creates Working record (app not running for this root)" test "$(state_of "$H" it-1)" = working
check "prompt text is never stored" bash -c "! grep -rq TOPSECRET '$H'"
hook "$H" '{"session_id":"it-1","hook_event_name":"Stop"}' >/dev/null
check "Stop -> Complete" test "$(state_of "$H" it-1)" = complete
perm="$(stat -f %Lp "$H/sessions/it-1.json")"; dperm="$(stat -f %Lp "$H/sessions")"
check "record mode 600, directory mode 700" test "$perm" = 600 -a "$dperm" = 700
for bad in '' 'garbage' '[]' '{"session_id":"../../x","hook_event_name":"Stop"}' '{"hook_event_name":"Stop"}' '{"session_id":"a","hook_event_name":"Stop$(id)"}'; do
  out="$(hook "$H" "$bad" 2>&1)"; rc=$?
  check "malformed input fails open (exit 0, silent): ${bad:0:40}" test "$rc" = 0 -a -z "$out"
done
check "malformed input never creates files outside sessions" test ! -e "$H/../x.json" -a ! -e "$WORK/x.json"
BIG="$WORK/big.json"
python3 -c "import json;print(json.dumps({'session_id':'it-big','hook_event_name':'PostToolUse','tool_use_id':'t','tool_response':'x'*6_000_000}))" > "$BIG"
env -i HOME="$HOME" PATH=/usr/bin:/bin CLAUDE_STATUS_HOME="$H" "$HOOK" < "$BIG"; rc=$?
check "6 MB payload handled via bounded read + prefix scan" test "$rc" = 0 -a -f "$H/sessions/it-big.json"
RO="$WORK/readonly"; mkdir -p "$RO"; chmod 500 "$RO"
out="$(hook "$RO/home" '{"session_id":"ro","hook_event_name":"Stop"}' 2>&1)"; rc=$?
check "unwritable state root still exits 0 silently" test "$rc" = 0 -a -z "$out"
# Lock held by another process: hook gives up after ~1 s and still exits 0.
mkdir -p "$WORK/h2/sessions"
python3 - "$WORK/h2/sessions/.store.lock" <<'PY' &
import fcntl, sys, time
f = open(sys.argv[1], "w"); fcntl.flock(f, fcntl.LOCK_EX); time.sleep(4)
PY
LOCKER=$!; sleep 0.5
t0=$(python3 -c 'import time;print(time.time())')
hook "$WORK/h2" '{"session_id":"lk","hook_event_name":"Stop"}'; rc=$?
t1=$(python3 -c 'import time;print(time.time())')
kill $LOCKER 2>/dev/null || true
check "lock contention bounded (<2 s) and fails open" python3 -c "import sys; sys.exit(0 if $rc==0 and ($t1-$t0)<2.0 else 1)"
# Corrupt record recovery.
echo '{broken' > "$H/sessions/it-c.json"
hook "$H" '{"session_id":"it-c","hook_event_name":"UserPromptSubmit"}'
check "corrupt record replaced on next event" test "$(state_of "$H" it-c)" = working
# Concurrent hooks across sessions.
for i in $(seq 1 60); do hook "$H" "{\"session_id\":\"conc-$((i % 3))\",\"hook_event_name\":\"PreToolUse\",\"tool_use_id\":\"t$i\"}" & done; wait
n=0; for f in "$H"/sessions/conc-*.json; do [[ -f "$f" ]] && n=$((n+1)); done; bad_json=0
for f in "$H"/sessions/conc-*.json; do python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$f" || bad_json=1; done
logged=$(grep -c " conc-" "$H/logs/hook.log")
check "60 concurrent hook processes: 3 intact records, all 60 events processed" test "$n" = 3 -a "$bad_json" = 0 -a "$logged" = 60
# Latency.
LAT="$WORK/lat"; mkdir -p "$LAT"
python3 - "$HOOK" "$LAT" > "$WORK/latency.txt" <<'PY'
import os, statistics, subprocess, sys, time
hook, home = sys.argv[1], sys.argv[2]
env = {"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin", "CLAUDE_STATUS_HOME": home}
samples = []
for i in range(100):
    payload = ('{"session_id":"lat","hook_event_name":"%s","tool_use_id":"t%d","cwd":"%s"}'
               % ("PreToolUse" if i % 2 == 0 else "PostToolUse", i // 2, os.getcwd())).encode()
    t = time.perf_counter(); subprocess.run([hook], input=payload, env=env, check=True)
    samples.append((time.perf_counter() - t) * 1000)
samples.sort()
print("median=%.1fms p95=%.1fms max=%.1fms" % (statistics.median(samples), samples[94], samples[-1]))
sys.exit(0 if samples[94] < 100 else 1)
PY
lat_rc=$?
check "hook latency p95 < 100 ms ($(cat "$WORK/latency.txt"))" test $lat_rc = 0

echo "Settings configuration (fixtures)"
HP="$WORK/ClaudeStatus/bin/claude-status-hook"
ctl() { "$CTL" "$@" --home "$WORK/ctlhome" --hook-path "$HP"; }
for fx in empty-object unrelated existing-hooks; do
  S="$WORK/$fx.json"; cp "$FIX/$fx.json" "$S"; orig="$(sha "$S")"
  ctl install-hooks --settings "$S" >/dev/null
  check "$fx: installed and healthy" ctl verify-hooks --settings "$S"
  check "$fx: everything else preserved" ctl verify-preserved --settings "$S" --backup "$FIX/$fx.json"
  once="$(sha "$S")"; ctl install-hooks --settings "$S" >/dev/null
  check "$fx: second install is a no-op (byte-identical)" test "$(sha "$S")" = "$once"
  ctl uninstall-hooks --settings "$S" >/dev/null
  check "$fx: uninstall restores original bytes" test "$(sha "$S")" = "$orig"
done
S="$WORK/missing/settings.json"
ctl install-hooks --settings "$S" >/dev/null
check "missing settings file: created and healthy" ctl verify-hooks --settings "$S"
S="$WORK/existing-hooks.json"; cp "$FIX/existing-hooks.json" "$S"
ctl install-hooks --settings "$S" >/dev/null
check "sleep-prevention hook preserved verbatim" grep -q 'caffeinate -i -t 3600' "$S"
for i in 1 2 3 4 5 6; do ctl install-hooks --settings "$S" >/dev/null 2>&1 & done; wait
check "6 concurrent installs: healthy, no duplicates" ctl verify-hooks --settings "$S"
check "6 concurrent installs: other settings preserved" ctl verify-preserved --settings "$S" --backup "$FIX/existing-hooks.json"
python3 - "$S" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["laterChange"] = True; d["hooks"]["Stop"].append({"hooks": [{"type": "command", "command": "later-hook"}]})
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
ctl uninstall-hooks --settings "$S" >/dev/null
check "uninstall keeps later changes and later hooks" python3 -c "
import json,sys; d=json.load(open('$S')); c=json.dumps(d)
sys.exit(0 if d.get('laterChange') and 'later-hook' in c and 'claude-status-hook' not in c else 1)"
check "restore-backup refuses when settings changed since backup" bash -c "! '$CTL' restore-backup --settings '$S' --backup '$FIX/existing-hooks.json' >/dev/null 2>&1"
for fx in invalid-json hooks-not-object; do
  S="$WORK/$fx.json"; cp "$FIX/$fx.json" "$S"; orig="$(sha "$S")"
  check "$fx: install refused (non-zero exit)" bash -c "! '$CTL' install-hooks --settings '$S' --home '$WORK/ctlhome' --hook-path '$HP' >/dev/null 2>&1"
  check "$fx: file untouched" test "$(sha "$S")" = "$orig"
done
if [[ -f "$SETTINGS" ]]; then
  # Baseline = the real file without any Claude Status hooks (it may already be installed).
  S="$WORK/real-copy.json"; cp -p "$SETTINGS" "$S"
  ctl uninstall-hooks --settings "$S" >/dev/null
  BASE="$WORK/real-baseline.json"; cp -p "$S" "$BASE"; orig="$(sha "$S")"
  ctl install-hooks --settings "$S" >/dev/null
  removed="$(diff "$BASE" "$S" | grep -c '^<' || true)"
  check "copy of real settings: install is purely additive (0 lines removed)" test "$removed" = 0
  check "copy of real settings: preserved" ctl verify-preserved --settings "$S" --backup "$SETTINGS"
  check "copy of real settings: baseline equals real file minus Claude Status hooks" ctl verify-preserved --settings "$BASE" --backup "$SETTINGS"
  ctl uninstall-hooks --settings "$S" >/dev/null
  check "copy of real settings: install+uninstall byte-identical" test "$(sha "$S")" = "$orig"
fi
check "backups written with mode 600" bash -c "for f in '$WORK/ctlhome/backups/'*.bak; do [ \$(stat -f %Lp \"\$f\") = 600 ] || exit 1; done"

echo "Diagnostics"
DH="$WORK/diag"; mkdir -p "$DH"
S="$WORK/diag-settings.json"; cp "$FIX/unrelated.json" "$S"
"$CTL" install-hooks --settings "$S" --home "$DH" --hook-path "$DH/bin/claude-status-hook" >/dev/null
"$CTL" diagnose --json --settings "$S" --home "$DH" > "$WORK/diag.json"; rc=$?
check "missing hook executable detected (exit 2, reported)" bash -c "[ $rc = 2 ] && grep -q '\"hookExecutablePresent\" : false' '$WORK/diag.json'"
mkdir -p "$DH/bin"; cp "$HOOK" "$DH/bin/claude-status-hook"
"$CTL" diagnose --json --settings "$S" --home "$DH" > "$WORK/diag2.json"; rc=$?
# Real Claude sessions on this Mac are unobserved in this empty store: a coverage warning is the
# only acceptable problem.
check "healthy after executable restored (only coverage gaps reported)" python3 -c "
import json,sys; d=json.load(open(sys.argv[1]))
ok = d['level']=='ok' or (d['level']=='warning' and all(p.startswith('Monitoring incomplete') for p in d['problems']))
sys.exit(0 if ok and $rc == 0 and d['hookExecutablePresent'] else 1)" "$WORK/diag2.json"

echo "Menu bar application (isolated instance, own state root)"
AH="$WORK/app"; mkdir -p "$AH/sessions"; chmod 700 "$AH" "$AH/sessions"
DUMP="$AH/state-dump.json"
# Pre-existing state: an old finished session (beyond retention) and an old active one.
old=$(( $(date +%s) - 3 * 86400 ))
hook "$AH" '{"session_id":"old-done","hook_event_name":"Stop","background_tasks":[]}'
hook "$AH" '{"session_id":"old-busy","hook_event_name":"PermissionRequest"}'
for f in old-done old-busy; do
  python3 - "$AH/sessions/$f.json" "$old" <<'PY'
import json, sys
p, t = sys.argv[1], float(sys.argv[2]); d = json.load(open(p)); d["lastEventAt"] = t; d["firstSeenAt"] = t; json.dump(d, open(p, "w"))
PY
done
start_app() {
  CLAUDE_STATUS_HOME="$AH" CLAUDE_STATUS_STATE_DUMP="$DUMP" "$APPBIN" -completedRetentionHours 24 >/dev/null 2>&1 &
  LAST_APP_PID=$!
  APP_PIDS+=("$LAST_APP_PID")
  for _ in $(seq 1 40); do [[ -f "$DUMP" ]] && break; sleep 0.25; done
}
# Real Claude processes on this Mac appear as unobserved sessions in the isolated instance;
# `S(d)` is the list of visible sessions that came from hook events. (When this test runs inside
# a Claude Code session, the hook finds that live `claude` process as its ancestor, so retention
# hides old finished records instead of deleting them.)
dump() { python3 -c "import json,sys; d=json.load(open('$DUMP')); S=lambda d: [s for s in d['sessions'] if not s['unobserved'] and not s['dismissed']]; print(eval(sys.argv[1]))" "$1" 2>/dev/null; }
wait_for() { # python-expr expected timeout_s
  local end=$(( $(date +%s) + ${3:-5} ))
  while (( $(date +%s) <= end )); do [[ "$(dump "$1")" == "$2" ]] && return 0; sleep 0.05; done; return 1
}
start_app
check "app starts and publishes state" test -f "$DUMP"
check "retention removed/hid old finished session, kept old waiting one" wait_for "sorted(s['id'] for s in S(d))" "['old-busy']" 5
check "aggregate Waiting while a session awaits approval" wait_for "d['aggregate']" "waiting" 3
hook "$AH" '{"session_id":"old-busy","hook_event_name":"PostToolUse"}'
check "approval resolved -> Working" wait_for "d['aggregate']" "working" 3
# Event-to-indicator latency.
python3 - "$HOOK" "$AH" "$DUMP" > "$WORK/e2e.txt" <<'PY'
import json, os, subprocess, sys, time
hook, home, dump = sys.argv[1:4]
env = {"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin", "CLAUDE_STATUS_HOME": home}
res = []
for i in range(10):
    sid = "lat-%d" % i
    t = time.time()
    subprocess.run([hook], input=('{"session_id":"%s","hook_event_name":"UserPromptSubmit"}' % sid).encode(), env=env, check=True)
    elapsed = 9.99
    while time.time() - t < 5:
        try:
            d = json.load(open(dump))
            if any(s["id"] == sid and s["state"] == "working" for s in d["sessions"]):
                elapsed = time.time() - t
                break
        except Exception:
            pass
        time.sleep(0.005)
    res.append(elapsed)
res.sort()
print("median=%.0fms max=%.0fms" % (res[len(res)//2] * 1000, res[-1] * 1000))
sys.exit(0 if res[-1] < 1.0 else 1)
PY
e2e_rc=$?
check "event-to-indicator latency < 1 s ($(cat "$WORK/e2e.txt"))" test $e2e_rc = 0
for i in 0 1 2 3 4 5 6 7 8 9; do hook "$AH" "{\"session_id\":\"lat-$i\",\"hook_event_name\":\"Stop\",\"background_tasks\":[]}"; done
hook "$AH" '{"session_id":"multi-a","hook_event_name":"UserPromptSubmit"}'
hook "$AH" '{"session_id":"multi-b","hook_event_name":"StopFailure","error":"rate_limit"}'
check "concurrent sessions: each listed individually" wait_for "len(S(d))" "13" 3
check "aggregate precedence: Error over Working" wait_for "d['aggregate']" "error" 3
check "working count preserved alongside error" wait_for "d['working']" "2" 3
# Restart recovery.
kill "$LAST_APP_PID"; wait "$LAST_APP_PID" 2>/dev/null; rm -f "$DUMP"
hook "$AH" '{"session_id":"multi-b","hook_event_name":"UserPromptSubmit"}'   # event while app is down
start_app
check "restart: state recovered incl. events received while app was down" wait_for "(d['aggregate'], d['working'], len(S(d)))" "('working', 3, 13)" 5
# Background work (documented background_tasks on Stop) through the real hook and app.
lbl() { echo "[s['label'] for s in d['sessions'] if s['id']=='$1'][0]"; }
hook "$AH" '{"session_id":"bg-1","hook_event_name":"UserPromptSubmit","prompt":"x"}'
hook "$AH" '{"session_id":"bg-1","hook_event_name":"Stop","background_tasks":[{"id":"t1","type":"shell","status":"running","command":"sleep 40"}],"session_crons":[]}'
check "Stop with a running background task -> Working — Background" wait_for "$(lbl bg-1)" "Working — Background" 3
check "background work counts as working in the aggregate" wait_for "d['background'] >= 1" "True" 3
hook "$AH" '{"session_id":"bg-1","hook_event_name":"UserPromptSubmit","prompt":"<task notification>"}'
check "automatic continuation -> Working" wait_for "$(lbl bg-1)" "Working" 3
hook "$AH" '{"session_id":"bg-1","hook_event_name":"Stop","background_tasks":[],"session_crons":[]}'
check "all work finished -> Complete" wait_for "$(lbl bg-1)" "Complete" 3
hook "$AH" '{"session_id":"bg-2","hook_event_name":"Stop"}'
check "Stop without background report -> Unknown, not Complete" wait_for "$(lbl bg-2)" "Unknown" 3
check "record holds no command text" bash -c "! grep -q 'sleep 40' '$AH/sessions/bg-1.json'"
# Existing sessions: Claude processes running on this Mac are listed as unobserved (Unknown).
if pgrep -x claude >/dev/null 2>&1; then
  check "running Claude sessions without events are shown as unobserved, never omitted" wait_for "d['unobserved'] > 0 and d['aggregate'] != 'idle'" "True" 40
else
  echo "  SKIP  unobserved-session discovery (no Claude Code process running on this machine)"
fi
# Missing hook executable is surfaced by the app's health model (isolated root has none).
check "app health reports missing hook executable" wait_for "d['hookExecutablePresent']" "False" 3
# Ingestion recovery: sessions directory removed and recreated.
mv "$AH/sessions" "$AH/sessions.moved"
mkdir "$AH/sessions"; chmod 700 "$AH/sessions"
hook "$AH" '{"session_id":"after-recreate","hook_event_name":"UserPromptSubmit"}'
# The 30 s periodic tick (10 s timer tolerance) re-arms the watcher and reloads.
check "watcher re-arms after state directory replacement" wait_for "'after-recreate' in [s['id'] for s in d['sessions']]" "True" 45

echo
echo "Integration: $PASS passed, $FAIL failed"
[[ $FAIL == 0 ]]
