#!/usr/bin/env python3
"""Live acceptance test against the INSTALLED Claude Status and a real Claude Code CLI.

Drives a dedicated interactive CLI test session in a pseudo-terminal through the scenarios
of the compatibility matrix and checks the status Claude Status derives for it
(`claude-status-ctl list --json`, the same code as the menu bar). Uses a few short turns of
the user's normal Claude plan and only the harmless scripts/acceptance/bgtask.sh.

Safety: permission prompts are NEVER approved by this script. A permission request is
observed as Waiting and then declined with Esc. AskUserQuestion (a question to the user,
not a tool permission) is answered by choosing its first option. Terminal output is not
stored; Claude Status state holds no prompt or response text.

usage: python3 scripts/acceptance/cli_acceptance.py [--cwd DIR] [--only a,b,...] [--json OUT]
scenarios: basic, permission, question, bg-multi, bg-cancel, subagent, monitor, schedule,
           esc-tool, esc-gen, concurrent, exit
"""
import argparse, json, os, pty, select, signal, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
BGTASK = os.path.join(HERE, "bgtask.sh")
CTL = os.path.expanduser("~/Library/Application Support/ClaudeStatus/bin/claude-status-ctl")

ap = argparse.ArgumentParser()
ap.add_argument("--cwd", default=REPO)
ap.add_argument("--only", default="")
ap.add_argument("--json", default=os.path.join(os.environ.get("TMPDIR", "/tmp"), "claude-status-cli-acceptance.json"))
a = ap.parse_args()
ONLY = set(x for x in a.only.split(",") if x)
def want(n): return not ONLY or n in ONLY

results, timeline = [], []
T0 = time.time()
def log(msg): print("%7.1fs %s" % (time.time() - T0, msg), flush=True)
def check(scenario, name, cond, detail=""):
    results.append({"scenario": scenario, "check": name, "status": "PASS" if cond else "FAIL", "detail": detail})
    log("  %s  [%s] %s%s" % ("PASS" if cond else "FAIL", scenario, name, (" — " + str(detail)) if detail else ""))
def skip(scenario, name, why):
    results.append({"scenario": scenario, "check": name, "status": "SKIP", "detail": why})
    log("  SKIP  [%s] %s — %s" % (scenario, name, why))

env = {k: os.environ[k] for k in ("HOME", "USER", "LOGNAME", "SHELL", "LANG", "TMPDIR") if k in os.environ}
env.update({"PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "xterm-256color",
            "COLUMNS": "120", "LINES": "40"})

class Session:
    def __init__(self, first_prompt="Reply with exactly the word READY and nothing else."):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(a.cwd)
            os.execvpe("claude", ["claude", "--permission-mode", "default", "--allowedTools", "Bash(%s *)" % BGTASK,
                                  "--", first_prompt], env)
        self.last = None
    def pump(self, t=0.05):
        end = time.time() + t
        while time.time() < end:
            r, _, _ = select.select([self.fd], [], [], max(0, end - time.time()))
            if r:
                try: os.read(self.fd, 65536)
                except OSError: return
    def send(self, s):
        for ch in s: os.write(self.fd, ch.encode()); self.pump(0.01)
    def key(self, b): os.write(self.fd, b); self.pump(0.3)
    def row(self):
        try:
            d = json.loads(subprocess.run([CTL, "list", "--json"], capture_output=True, text=True, timeout=20).stdout)
        except Exception:
            return None
        r = next((s for s in d["sessions"] if s.get("pid") == self.pid and not s.get("unobserved")), None)
        if r:
            k = (r["label"], r.get("backgroundActive"), r["lastEvent"])
            if k != self.last:
                self.last = k
                timeline.append({"t": round(time.time() - T0, 1), "pid": self.pid, "label": r["label"],
                                 "bg": r.get("backgroundActive"), "event": r["lastEvent"]})
                log("    %-34s bg=%-4s last=%s" % (r["label"], r.get("backgroundActive"), r["lastEvent"]))
        return r
    def wait(self, pred, timeout, seen=None):
        end = time.time() + timeout
        r = None
        while time.time() < end:
            self.pump(0.5)
            r = self.row()
            if r and seen is not None: seen.add(r["label"])
            if r and pred(r): return r
        return r
    def prompt(self, text):
        r = self.row()
        if r and r["state"] == "waiting":
            log("    (open dialog: declining with Esc — never approved)")
            self.key(b"\x1b"); self.pump(2); self.key(b"\x03"); self.pump(1)
        self.pump(0.5); self.send(text); time.sleep(0.4); self.send("\r")
        return time.time()
    def done(self, r, after): return r["label"] == "Complete" and r["lastEvent"] in ("Stop", "SubagentStop") and time.time() > after + 1
    def close(self):
        end = time.time() + 10
        while time.time() < end:
            self.pump(0.1)
            try:
                d, _ = os.waitpid(self.pid, os.WNOHANG)
                if d: return
            except ChildProcessError: return
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try: os.kill(self.pid, sig)
            except ProcessLookupError: return
            time.sleep(3)

s = Session()
log("CLI acceptance: claude pid %d" % s.pid)
try:
    seen = set()
    r = s.wait(lambda r: r["label"] == "Complete", 120, seen)
    check("basic", "session observed as a CLI session", r is not None and r["client"] == "cli", r and r["client"])
    check("basic", "prompt -> Working", any(x.startswith("Working") for x in seen), sorted(seen))
    check("basic", "turn ends -> Complete", r is not None and r["label"] == "Complete")

    if want("permission"):
        t = s.prompt("Permission test: use the Bash tool to run exactly: touch /tmp/cs-acceptance-%d   "
                     "If it is denied or interrupted, do nothing else." % os.getpid())
        r = s.wait(lambda r: r["state"] == "waiting" or s.done(r, t), 90)
        check("permission", "permission request -> Waiting — Approval required",
              r is not None and r["state"] == "waiting" and "Approval" in r["detail"], r and r["detail"])
        time.sleep(8)
        s.key(b"\x1b")   # decline (never approve)
        r = s.wait(lambda r: r["state"] != "waiting", 20)
        check("permission", "decline with Esc: no event, still Waiting (documented limitation)", r is not None and r["state"] == "waiting",
              r and r["label"])
        s.key(b"\x03")
        t = s.prompt("Reply only: ok")
        seen = set()
        r = s.wait(lambda r: s.done(r, t), 90, seen)
        check("permission", "next prompt resolves Waiting -> Working -> Complete", r is not None and r["label"] == "Complete" and "Working" in seen)
        check("permission", "declined tool did not run", not os.path.exists("/tmp/cs-acceptance-%d" % os.getpid()))

    if want("question"):
        t = s.prompt("Question test: use the AskUserQuestion tool to ask me to choose between options Alpha and Beta. "
                     "After I answer, reply only with the chosen word.")
        r = s.wait(lambda r: r["state"] == "waiting" or s.done(r, t), 90)
        check("question", "AskUserQuestion -> Waiting — Question for you (not 'Approval required')",
              r is not None and r["state"] == "waiting" and r["detail"] == "Question for you", r and r["detail"])
        time.sleep(3)
        s.key(b"\r")   # answer: first option
        seen = set()
        r = s.wait(lambda r: s.done(r, t), 90, seen)
        check("question", "answered -> Working -> Complete", r is not None and r["label"] == "Complete" and "Working" in seen)
        t = s.prompt("Question test 2: use the AskUserQuestion tool to ask me to choose between options Red and Blue.")
        r = s.wait(lambda r: r["state"] == "waiting" or s.done(r, t), 90)
        time.sleep(3)
        s.key(b"\x1b")   # cancel the question
        r = s.wait(lambda r: r["state"] != "waiting", 15)
        check("question", "question cancelled with Esc: no event, still Waiting (documented limitation)",
              r is not None and r["state"] == "waiting", r and r["label"])
        s.key(b"\x03")

    if want("bg-multi"):
        t = s.prompt("Background test: in ONE message start two Bash tool calls, both with run_in_background true: "
                     "(1) %s 15   (2) %s 35 3   Then end your turn immediately replying only: started. "
                     "Each time you are notified one finished, reply with one word (ok or failed), no tools." % (BGTASK, BGTASK))
        r = s.wait(lambda r: r["label"] == "Working — Background", 90)
        check("bg-multi", "turn ends with 2 running tasks -> Working — Background (2)", r is not None and r.get("backgroundActive") == 2,
              r and (r["label"], r.get("backgroundActive")))
        seen = set()
        r = s.wait(lambda r: r["label"] == "Working — Background" and r.get("backgroundActive") == 1, 60, seen)
        check("bg-multi", "first exits -> Claude continues -> 1 task left", r is not None and r.get("backgroundActive") == 1)
        check("bg-multi", "automatic continuation shown as Working — Continuing", "Working — Continuing" in seen, sorted(seen))
        r = s.wait(lambda r: s.done(r, t + 30), 90)
        check("bg-multi", "failing task exits -> continuation -> Complete (no background left)", r is not None and r["label"] == "Complete")

    if want("bg-cancel"):
        t = s.prompt("Cancel test: start a Bash tool call with run_in_background true running exactly: %s 600   "
                     "Then end your turn replying only: started." % BGTASK)
        r = s.wait(lambda r: r["label"] == "Working — Background", 90)
        check("bg-cancel", "long background task -> Working — Background", r is not None)
        t = s.prompt("Now stop that background task with the TaskStop tool (or KillShell) and reply only: stopped.")
        r = s.wait(lambda r: s.done(r, t), 90)
        check("bg-cancel", "TaskStop -> Complete (Stop reports no background work)", r is not None and r["label"] == "Complete")

    if want("subagent"):
        t = s.prompt("Subagent test: use the Agent tool with run_in_background true and subagent_type general-purpose, with the prompt "
                     "'Run the Bash tool in the foreground with exactly: %s 20   then reply only: sub-done.' "
                     "End your own turn immediately replying only: launched. When it reports back, reply only: received (no tools)." % BGTASK)
        r = s.wait(lambda r: r["label"] == "Working — Background", 120)
        check("subagent", "parent finished, background subagent running -> Working — Background",
              r is not None and "subagent" in r["detail"], r and r["detail"])
        r = s.wait(lambda r: s.done(r, t + 15), 150)
        check("subagent", "subagent reports, parent continues and finishes -> Complete", r is not None and r["label"] == "Complete")

    if want("monitor"):
        t = s.prompt("Monitor test: if you have a Monitor tool, use it to watch the output of exactly: %s 20   "
                     "and end your turn replying only: monitoring; when it reports, reply only: ok. Without a Monitor tool reply only: no-monitor." % BGTASK)
        r = s.wait(lambda r: r["label"] == "Working — Background" or s.done(r, t), 90)
        if r and r["label"] == "Working — Background":
            check("monitor", "monitor running -> Working — Background", True, r["detail"])
            r = s.wait(lambda r: s.done(r, t + 15), 120)
            check("monitor", "monitor finished -> Complete", r is not None and r["label"] == "Complete")
        else:
            skip("monitor", "monitor", "the model reported no Monitor tool")

    if want("schedule"):
        lt = time.localtime(time.time() + 130)
        t = s.prompt("Schedule test: create a ONE-SHOT schedule with the CronCreate tool (recurring false), cron expression "
                     "'%d %d %d %d *' and prompt 'Reply only: woke.' Then end your turn replying only: scheduled." % (lt.tm_min, lt.tm_hour, lt.tm_mday, lt.tm_mon))
        r = s.wait(lambda r: r["label"] == "Continuation scheduled" or s.done(r, t), 90)
        check("schedule", "one-shot wakeup -> Continuation scheduled with its time",
              r is not None and r["label"] == "Continuation scheduled" and "%02d:%02d" % (lt.tm_hour, lt.tm_min) in r["detail"], r and r["detail"])
        seen = set()
        r = s.wait(lambda r: s.done(r, t + 60), 240, seen)
        check("schedule", "wakeup fires -> Working — Continuing -> Complete", r is not None and r["label"] == "Complete" and "Working — Continuing" in seen, sorted(seen))
        lt = time.localtime(time.time() + 900)
        t = s.prompt("Create another ONE-SHOT CronCreate schedule '%d %d %d %d *' with prompt 'Reply only: late.' and end your turn replying only: scheduled."
                     % (lt.tm_min, lt.tm_hour, lt.tm_mday, lt.tm_mon))
        r = s.wait(lambda r: r["label"] == "Continuation scheduled", 90)
        t = s.prompt("Now delete that schedule with the CronDelete tool and reply only: deleted.")
        r = s.wait(lambda r: s.done(r, t), 90)
        check("schedule", "schedule cancelled -> Complete", r is not None and r["label"] == "Complete")

    if want("esc-tool"):
        t = s.prompt("Interrupt test: run the Bash tool in the FOREGROUND (run_in_background false) with exactly: %s 60" % BGTASK)
        r = s.wait(lambda r: r["foreground"] == "Running tool" or s.done(r, t), 60)
        if r and r["foreground"] == "Running tool":
            time.sleep(4)
            s.key(b"\x1b")
            r = s.wait(lambda r: r["label"] != "Working", 30)
            log("    after Esc during a tool: %s (%s)" % (r and r["label"], r and r["lastEvent"]))
            check("esc-tool", "interrupted tool is never shown Complete or Error", r is not None and r["state"] not in ("complete", "error"), r and r["label"])
            s.key(b"\x03")
            t = s.prompt("Reply only: ok")
            r = s.wait(lambda r: s.done(r, t), 90)
            check("esc-tool", "next prompt -> normal turn -> Complete", r is not None and r["label"] == "Complete")
        else:
            skip("esc-tool", "interrupt a running tool", "the model did not start the tool")

    if want("esc-gen"):
        t = s.prompt("Write a detailed 2000-word essay about the history of lighthouses. Do not use any tools.")
        r = s.wait(lambda r: r["state"] == "working", 30)
        time.sleep(4)
        s.key(b"\x1b")
        r = s.wait(lambda r: r["state"] != "working", 20)
        check("esc-gen", "Esc during generation emits no event: still Working (until the next event or the limit)",
              r is not None and r["state"] == "working", r and r["label"])
        s.key(b"\x03")
        t = s.prompt("Reply only: ok")
        r = s.wait(lambda r: s.done(r, t), 90)
        check("esc-gen", "next prompt -> Complete", r is not None and r["label"] == "Complete")

    if want("concurrent"):
        s2 = Session("Concurrency test: run the Bash tool in the foreground with exactly: %s 20   then reply only: two." % BGTASK)
        t = s.prompt("Concurrency test: start a Bash tool call with run_in_background true running exactly: %s 30   "
                     "then end your turn replying only: one; when notified reply only: done." % BGTASK)
        r2 = s2.wait(lambda r: r["state"] == "working", 60)
        r1 = s.wait(lambda r: r["label"] == "Working — Background", 60)
        check("concurrent", "two sessions in the same folder are separate rows with their own states",
              r1 is not None and r2 is not None and r1["id"] != r2["id"], (r1 and r1["label"], r2 and r2["label"]))
        r2 = s2.wait(lambda r: r["label"] == "Complete", 120)
        r1 = s.wait(lambda r: s.done(r, t + 20), 120)
        check("concurrent", "both finish independently -> Complete", r1 is not None and r2 is not None and r1["label"] == r2["label"] == "Complete")
        # Abrupt termination of the second session (no SessionEnd possible).
        s2.prompt("Write a 600-word story about a lighthouse keeper. Do not use any tools.")
        s2.wait(lambda r: r["state"] == "working", 30)
        os.kill(s2.pid, signal.SIGKILL)
        try: os.waitpid(s2.pid, 0)
        except ChildProcessError: pass
        time.sleep(1)
        r2 = s2.row()
        check("concurrent", "session killed mid-turn -> Unknown (process exited), never Complete",
              r2 is not None and r2["state"] == "unknown" and r2["processExited"], r2 and r2["label"])

    s.key(b"\x03"); s.pump(1)
    s.prompt("/exit")
    r = s.wait(lambda r: r["ended"], 30)
    check("exit", "/exit -> SessionEnd -> ended", r is not None and r["ended"])
finally:
    s.close()

json.dump({"results": results, "timeline": timeline}, open(a.json, "w"), indent=1)
p = sum(1 for x in results if x["status"] == "PASS")
f = sum(1 for x in results if x["status"] == "FAIL")
k = sum(1 for x in results if x["status"] == "SKIP")
log("CLI acceptance: %d passed, %d failed, %d skipped (details: %s)" % (p, f, k, a.json))
sys.exit(0 if f == 0 else 1)
