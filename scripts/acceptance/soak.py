#!/usr/bin/env python3
"""Extended-duration monitoring test (default 31 minutes) against the INSTALLED Claude Status.

Drives one dedicated Claude Code CLI test session in a pseudo-terminal and samples the state
Claude Status derives (`claude-status-ctl list --json`) every few seconds for the CLI session
and for any extra session id prefixes given with --watch PREFIX=EXPECTATION. Records sanitized
transitions (id prefix, label, activity, confidence, background count) to a JSONL file and
checks invariants:

  CLI timeline (T = start):
    T+0      background task of --bg-seconds (default 1560 s) started, turn ends
             -> Working — Background (never Complete, never Unknown while it runs)
    T+60s    long foreground tool (--fg-seconds, default 300 s) -> Working throughout
    T+8m     Claude Status app restarted (unexpected termination + relaunch); the derived
             state must be identical afterwards
    then     extended period without any hook event (background still running)
    bg exit  Claude continues on its own -> Complete
    end      /exit -> session ended

  --watch PREFIX=bg:SECONDS   a session with background work ending after SECONDS:
                              Working — Background until then, Complete afterwards
  --watch PREFIX=complete     an idle finished session: Complete throughout

Never approves a permission prompt: the CLI runs with an allow rule for the harmless
scripts/acceptance/bgtask.sh only, and any Waiting state is declined with Esc. Exits 0 only
when the full duration elapsed and every check passed. Cleans up its CLI process on exit.

usage: soak.py --out FILE [--minutes 31] [--bg-seconds 1560] [--fg-seconds 300]
               [--restart-at 480] [--watch PREFIX=bg:1440] [--watch PREFIX=complete]
"""
import argparse, json, os, pty, select, signal, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
BGTASK = os.path.join(HERE, "bgtask.sh")
CTL = os.path.expanduser("~/Library/Application Support/ClaudeStatus/bin/claude-status-ctl")
APP = os.path.expanduser("~/Applications/Claude Status.app")

ap = argparse.ArgumentParser()
ap.add_argument("--out", required=True)
ap.add_argument("--minutes", type=float, default=31)
ap.add_argument("--bg-seconds", type=int, default=1560)
ap.add_argument("--fg-seconds", type=int, default=300)
ap.add_argument("--restart-at", type=int, default=480)
ap.add_argument("--interval", type=float, default=5)
ap.add_argument("--watch", action="append", default=[])
a = ap.parse_args()

out = open(a.out, "a", buffering=1)
def log(kind, **kw):
    kw.update(kind=kind, t=round(time.time() - T0, 1))
    out.write(json.dumps(kw) + "\n")
    print(json.dumps(kw), flush=True)

failures = []
def fail(msg):
    failures.append(msg); log("FAIL", msg=msg)

env = {k: os.environ[k] for k in ("HOME", "USER", "LOGNAME", "SHELL", "LANG", "TMPDIR") if k in os.environ}
env.update({"PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "xterm-256color",
            "COLUMNS": "120", "LINES": "40"})

T0 = time.time()
pid, fd = pty.fork()
if pid == 0:
    os.chdir(REPO)
    os.execvpe("claude", ["claude", "--permission-mode", "default", "--allowedTools", "Bash(%s *)" % BGTASK, "--",
                          "Reply with exactly the word READY and nothing else."], env)

def pump(t=0.05):
    end = time.time() + t
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], max(0, end - time.time()))
        if r:
            try: os.read(fd, 65536)
            except OSError: return
def send(s):
    for ch in s: os.write(fd, ch.encode()); pump(0.01)

def snapshot():
    try:
        res = subprocess.run([CTL, "list", "--json"], capture_output=True, text=True, timeout=20)
        return json.loads(res.stdout)
    except Exception as e:
        return {"error": str(e), "sessions": []}

def cli_row(snap):
    return next((s for s in snap.get("sessions", []) if s.get("pid") == pid and not s.get("unobserved")), None)

def prompt(text):
    snap = snapshot(); row = cli_row(snap)
    if row and row["state"] == "waiting":
        log("note", msg="dialog open -> declining with Esc (never approved)")
        os.write(fd, b"\x1b"); pump(2); os.write(fd, b"\x03"); pump(1)
    pump(0.5); send(text); time.sleep(0.4); send("\r")

watch = {}
for w in a.watch:
    k, v = w.split("=", 1)
    watch[k] = v

def app_pids():
    r = subprocess.run(["pgrep", "-U", str(os.getuid()), "-x", "ClaudeStatus"], capture_output=True, text=True)
    pids = []
    for p in r.stdout.split():
        c = subprocess.run(["ps", "-o", "comm=", "-p", p], capture_output=True, text=True).stdout.strip()
        if c == APP + "/Contents/MacOS/ClaudeStatus": pids.append(int(p))
    return pids

last = {}
sid = None
bg_started_at = None
fg_started_at = None
fg_seen_working = 0
restarted = False
state_before_restart = None
bg_label_since = None
bg_seen = False
longest_bg_stretch = 0
complete_after_bg = False
ended = False
step = 0
deadline = T0 + a.minutes * 60
next_poll = 0
try:
    while time.time() < deadline:
        pump(0.2)
        now = time.time()
        el = now - T0
        if now < next_poll: continue
        next_poll = now + a.interval
        snap = snapshot()
        if "error" in snap: log("note", msg="ctl list failed: " + snap["error"][:80])
        row = cli_row(snap)
        if row and sid is None:
            sid = row["id"]; log("session", id=sid, client=row["client"])
        rows = {}
        if row: rows["cli"] = row
        for s in snap.get("sessions", []):
            for pre in watch:
                if s["id"].startswith(pre): rows[pre] = s
        for k, r in rows.items():
            key = (r["label"], r["activity"], r["confidence"], r.get("backgroundActive"))
            if last.get(k) != key:
                last[k] = key
                log("state", who=k, label=r["label"], activity=r["activity"], confidence=r["confidence"],
                    bg=r.get("backgroundActive"), lastEvent=r.get("lastEvent"), silence=r.get("silence"))
        # ---- CLI timeline ----
        if step == 0 and row and row["label"] == "Complete" and row["lastEvent"] in ("Stop", "SubagentStop"):
            prompt("Soak test. Use the Bash tool with run_in_background set to true to run exactly: %s %d   "
                   "Then end your turn immediately, replying only: started. When you are notified that it finished, "
                   "reply only: done (no tools)." % (BGTASK, a.bg_seconds))
            bg_started_at = time.time(); step = 1; log("step", n=1, msg="background task started")
        elif step == 1 and row and row["activity"] == "background" and el > 60:
            prompt("Now run the Bash tool in the FOREGROUND (run_in_background false, timeout 600000) with exactly: %s %d   "
                   "then reply only: fg-done." % (BGTASK, a.fg_seconds))
            fg_started_at = time.time(); step = 2; log("step", n=2, msg="long foreground tool started")
        elif step == 2:
            if row and row["state"] == "working" and row["activity"] == "foreground": fg_seen_working += a.interval
            if row and row["activity"] == "background" and time.time() - fg_started_at > a.fg_seconds - 30:
                step = 3; log("step", n=3, msg="foreground tool finished", fgWorkingSeconds=fg_seen_working)
                if fg_seen_working < a.fg_seconds - 60: fail("long foreground tool not shown as Working throughout (%ds)" % fg_seen_working)
        if not restarted and el > a.restart_at and step >= 3:
            state_before_restart = {k: (r["label"], r["activity"]) for k, r in rows.items()}
            pids = app_pids()
            log("step", n=4, msg="restarting Claude Status (SIGKILL + relaunch)", pids=len(pids))
            for p in pids: os.kill(p, signal.SIGKILL)
            time.sleep(2)
            subprocess.run(["open", "-a", APP])
            t_r = time.time()
            while time.time() - t_r < 20 and not app_pids(): time.sleep(0.5)
            restarted = True
            after = snapshot()
            arows = {}
            ar = cli_row(after)
            if ar: arows["cli"] = ar
            for s in after.get("sessions", []):
                for pre in watch:
                    if s["id"].startswith(pre): arows[pre] = s
            log("restart", relaunched=bool(app_pids()), seconds=round(time.time() - t_r, 1))
            if not app_pids(): fail("Claude Status did not relaunch")
            for k, v in state_before_restart.items():
                got = (arows[k]["label"], arows[k]["activity"]) if k in arows else None
                if got != v: fail("state of %s changed across restart: %s -> %s" % (k, v, got))
        # ---- invariants ----
        if row:
            # The task counts as running from the first time Claude Status reported it.
            if bg_started_at and row["activity"] == "background": bg_seen = True
            bg_running = bg_seen and time.time() - bg_started_at < a.bg_seconds - 5
            if bg_running and row["state"] == "complete": fail("CLI shown Complete while its background task runs")
            if row["state"] in ("unknown", "error") and not row.get("processExited"):
                fail("CLI shown %s (%s)" % (row["label"], row["detail"][:60]))
            if row["activity"] == "background":
                bg_label_since = bg_label_since or time.time()
                longest_bg_stretch = max(longest_bg_stretch, time.time() - bg_label_since)
            else:
                bg_label_since = None
            if bg_started_at and time.time() - bg_started_at > a.bg_seconds + 5 and row["label"] == "Complete":
                if not complete_after_bg: log("step", n=5, msg="background finished -> Complete")
                complete_after_bg = True
        for pre, exp in watch.items():
            r = rows.get(pre)
            if r is None: fail("watched session %s not listed" % pre); continue
            if exp == "complete" and r["label"] != "Complete": fail("%s expected Complete, got %s" % (pre, r["label"]))
            if exp.startswith("bg:"):
                end_at = T0 + float(exp[3:])
                if el > 90 and time.time() < end_at - 5 and r["state"] in ("complete", "unknown", "error"):
                    fail("%s shown %s while its background task runs" % (pre, r["label"]))
        if len(failures) > 50: break
    # ---- end ----
    log("step", n=6, msg="duration reached; exiting CLI session")
    os.write(fd, b"\x03"); pump(1); send("/exit"); time.sleep(0.4); send("\r")
    t_e = time.time()
    while time.time() - t_e < 30:
        pump(0.5)
        r = cli_row(snapshot()) or {}
        if r.get("ended"): ended = True; break
    final = snapshot()
    for pre, exp in watch.items():
        r = next((s for s in final.get("sessions", []) if s["id"].startswith(pre)), None)
        if exp.startswith("bg:") and (r is None or r["label"] != "Complete"):
            fail("%s not Complete after its background work ended (%s)" % (pre, r and r["label"]))
finally:
    # Reap the CLI without ever blocking indefinitely: wait, then SIGTERM, then SIGKILL.
    def reaped(seconds):
        end = time.time() + seconds
        while time.time() < end:
            pump(0.1)
            try:
                done, _ = os.waitpid(pid, os.WNOHANG)
                if done: return True
            except ChildProcessError:
                return True
        return False
    if not reaped(10):
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try: os.kill(pid, sig)
            except ProcessLookupError: break
            if reaped(8): break
    # Stop this run's background task if it is still running (exact command line only).
    subprocess.run(["pkill", "-f", "^/bin/sh %s %d$" % (BGTASK, a.bg_seconds)], capture_output=True)

dur = time.time() - T0
if dur < a.minutes * 60 - 5: fail("ended early after %.0fs" % dur)
if not restarted: fail("app restart step did not run")
if not complete_after_bg: fail("CLI never reached Complete after its background task ended")
if longest_bg_stretch < 15 * 60: fail("Working — Background was not held for 15 minutes without events (%.0fs)" % longest_bg_stretch)
if not ended: fail("CLI session not recorded as ended after /exit")
log("summary", seconds=round(dur), failures=len(failures), restarted=restarted, longestBackgroundSeconds=round(longest_bg_stretch),
    foregroundWorkingSeconds=fg_seen_working, completeAfterBackground=complete_after_bg, ended=ended)
print("SOAK %s: %d failure(s) in %.1f min" % ("PASS" if not failures else "FAIL", len(failures), dur / 60))
sys.exit(0 if not failures else 1)
