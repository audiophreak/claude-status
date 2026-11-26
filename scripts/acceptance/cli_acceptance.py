#!/usr/bin/env python3
"""Real-world acceptance test: drive a dedicated interactive Claude Code CLI session in a
pseudo-terminal and record the state transitions Claude Status observes for it.

Requires Claude Status to be installed (hooks registered) and the `claude` CLI logged in.
Uses a few short turns of the user's normal Claude plan. Never reads or prints prompt or
response text from Claude Status state (which holds none); terminal output is only scanned
for the trust dialog and is not stored.

usage: python3 scripts/acceptance/cli_acceptance.py [--cwd DIR] [--skip-interrupt]
"""
import json, os, pty, select, signal, subprocess, sys, time

STATE = os.path.expanduser("~/Library/Application Support/ClaudeStatus/sessions")
CWD = sys.argv[sys.argv.index("--cwd") + 1] if "--cwd" in sys.argv else os.getcwd()
SKIP_INTERRUPT = "--skip-interrupt" in sys.argv
MARK = "cs-acceptance-%d" % os.getpid()

results, transitions = [], []
def log(msg): print(msg, flush=True)
def check(name, cond, detail=""):
    results.append((name, bool(cond))); log("  %s  %s%s" % ("PASS" if cond else "FAIL", name, (" — " + detail) if detail else ""))

# Clean environment: no Desktop/parent-session variables leak into the CLI under test.
env = {k: os.environ[k] for k in ("HOME", "USER", "LOGNAME", "SHELL", "LANG", "TMPDIR") if k in os.environ}
env.update({"PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "xterm-256color",
            "COLUMNS": "120", "LINES": "40"})

pid, fd = pty.fork()
if pid == 0:
    os.chdir(CWD)
    os.execvpe("claude", ["claude", "--permission-mode", "default", "Reply with exactly the word READY and nothing else."], env)

screen = bytearray()
def pump(t=0.05):
    end = time.time() + t
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], max(0, end - time.time()))
        if r:
            try: data = os.read(fd, 65536)
            except OSError: return
            screen.extend(data)
            del screen[:-200_000]
def send(s):
    for ch in s:          # type like a user (Claude Code's TUI reads raw keystrokes)
        os.write(fd, ch.encode()); pump(0.01)

def find_record():
    best = None
    for n in os.listdir(STATE) if os.path.isdir(STATE) else []:
        if not n.endswith(".json") or n.startswith("."): continue
        try: r = json.load(open(os.path.join(STATE, n)))
        except Exception: continue
        if r.get("pid") == pid: best = r
    return best

last = None
def poll():
    global last
    pump(0.05)
    r = find_record()
    if r:
        key = (r["state"], r.get("reason"))
        if key != last:
            transitions.append((round(time.time() - T0, 2), r["state"], r.get("reason"), r.get("lastEventName")))
            log("    [%6.2fs] %-8s reason=%-14s last=%s" % (time.time() - T0, r["state"], r.get("reason"), r.get("lastEventName")))
            last = key
    return r

def wait_until(pred, timeout):
    end = time.time() + timeout
    seen = []
    while time.time() < end:
        r = poll()
        if r: seen.append(r["state"])
        if r and pred(r, seen): return r, seen
    return find_record(), seen

T0 = time.time()
log("CLI acceptance: claude pid %d, cwd %s" % (pid, CWD))
try:
    # 1. Session start + first prompt (passed on the command line).
    r, seen = wait_until(lambda r, s: r["state"] == "complete", 120)
    check("CLI session observed with client=cli", r is not None and r.get("client") == "cli", r and r.get("client"))
    check("prompt -> Working was observed", "working" in seen)
    check("turn completes -> Complete", r is not None and r["state"] == "complete")
    check("turn duration recorded", r is not None and (r.get("lastTurnDuration") or 0) > 0, r and "%.1fs" % (r.get("lastTurnDuration") or 0))
    sid = r and r["sessionId"]

    # 2. Permission prompt -> Waiting -> approve -> Working -> Complete.
    time.sleep(1)
    send("Use the Bash tool to run exactly this command and nothing else: mkdir -p /tmp/%s" % MARK)
    time.sleep(0.5); send("\r")
    r, seen = wait_until(lambda r, s: r["state"] in ("waiting", "complete") and "working" in s, 120)
    waited = r is not None and r["state"] == "waiting"
    check("permission request -> Waiting (approval required)", waited, r and "state=%s reason=%s" % (r["state"], r.get("reason")))
    if waited:
        time.sleep(1.0)
        send("\r")   # accept the highlighted "Yes" option
        r, seen = wait_until(lambda r, s: r["state"] == "complete", 120)
        check("after approval -> Working", "working" in seen)
        check("approved turn completes -> Complete", r is not None and r["state"] == "complete")
    check("approved tool actually ran", os.path.isdir("/tmp/" + MARK))
    try: os.rmdir("/tmp/" + MARK)
    except OSError: pass

    # 3. Interrupts (Esc). Claude Code documents no hook for an interrupt outside a tool,
    #    so these record what is actually emitted and assert only that an interrupted turn
    #    is never shown as Complete.
    if not SKIP_INTERRUPT:
        # 3a. Interrupt a running tool.
        time.sleep(1)
        send("This is a test of interrupting a tool. Use the Bash tool to run exactly: sleep 30 && echo finished")
        time.sleep(0.5); send("\r")
        r, seen = wait_until(lambda r, s: r["state"] == "complete" or r["state"] == "waiting"
                             or (r["state"] == "working" and r.get("inFlightTools")), 90)
        if r and r["state"] == "waiting":
            time.sleep(1.0); send("\r")
            r, seen = wait_until(lambda r, s: r["state"] == "complete" or (r["state"] == "working" and r.get("inFlightTools")), 60)
        if r and r["state"] == "working" and r.get("inFlightTools"):
            time.sleep(3)
            os.write(fd, b"\x1b")
            r, seen = wait_until(lambda r, s: r["state"] != "working", 75)
            log("    tool interrupt: state=%s reason=%s last=%s" % (r and r["state"], r and r.get("reason"), r and r.get("lastEventName")))
            check("tool interrupt is not reported as Complete", r is not None and r["state"] != "complete")
        else:
            log("  SKIP  tool interrupt — the model did not start the tool (state=%s)" % (r and r["state"]))
        # Return to a ready prompt.
        wait_until(lambda r, s: r["state"] != "working", 30)

        # 3b. Interrupt text generation (no tool in flight).
        time.sleep(2)
        send("Write a detailed 1500-word essay about the history of lighthouses. Do not use any tools.")
        time.sleep(0.5); send("\r")
        r, seen = wait_until(lambda r, s: r["state"] == "working" and r.get("lastEventName") == "UserPromptSubmit", 30)
        time.sleep(3)
        os.write(fd, b"\x1b")
        t_int = time.time()
        r, seen = wait_until(lambda r, s: r["state"] != "working", 80)
        log("    generation interrupt: state=%s reason=%s last=%s after %.0fs" % (
            r and r["state"], r and r.get("reason"), r and r.get("lastEventName"), time.time() - t_int))
        check("generation interrupt is not reported as Complete", r is not None and r["state"] != "complete")

    # 4. Exit -> SessionEnd -> ended. After an interrupt the TUI restores the interrupted
    #    prompt into the input box, so clear it (Ctrl-C clears non-empty input) first.
    time.sleep(1)
    os.write(fd, b"\x03"); pump(1.0)
    send("/exit"); time.sleep(0.5); send("\r")
    r, seen = wait_until(lambda r, s: r.get("ended"), 30)
    check("/exit -> SessionEnd recorded (ended)", r is not None and r.get("ended"), r and "reason=%s" % r.get("endReason"))
finally:
    # Keep draining the pty while the CLI shuts down; a full pty buffer would block it.
    def reap(seconds):
        end = time.time() + seconds
        while time.time() < end:
            pump(0.1)
            try:
                done, _ = os.waitpid(pid, os.WNOHANG)
            except ChildProcessError:
                return True
            if done: return True
        return False
    if not reap(10):
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try: os.kill(pid, sig)
            except ProcessLookupError: break
            if reap(5): break

# 5. Abrupt termination: a second CLI session is SIGKILLed mid-turn (no SessionEnd possible).
if "--skip-kill" not in sys.argv:
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(CWD)
        os.execvpe("claude", ["claude", "--permission-mode", "default", "Write a 400-word story about a lighthouse keeper. Do not use any tools."], env)
    last = None
    T0 = time.time()
    log("Abrupt-termination session: claude pid %d" % pid)
    r, seen = wait_until(lambda r, s: r["state"] == "working", 60)
    os.kill(pid, signal.SIGKILL)
    try: os.waitpid(pid, 0)
    except ChildProcessError: pass
    time.sleep(0.5)
    rec = find_record()
    check("killed session has no SessionEnd (not marked ended in the record)", rec is not None and not rec.get("ended"))
    listing = subprocess.run([os.path.expanduser("~/Library/Application Support/ClaudeStatus/bin/claude-status-ctl"), "list"],
                             capture_output=True, text=True).stdout
    line = next((l for l in listing.splitlines() if rec and l.startswith(rec["sessionId"][:8])), "")
    check("killed mid-turn session is shown as Unknown (process exited), not Working/Complete",
          "Unknown" in line and "process exited" in line, line.strip())

out = {"session": sid, "transitions": transitions, "results": results}
path = os.path.join(os.environ.get("TMPDIR", "/tmp"), "claude-status-cli-acceptance.json")
json.dump(out, open(path, "w"), indent=1)
passed = sum(1 for _, ok in results if ok)
log("CLI acceptance: %d/%d passed (transcript of states: %s)" % (passed, len(results), path))
sys.exit(0 if passed == len(results) else 1)
