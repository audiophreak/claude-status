#!/usr/bin/env python3
"""Record the status the INSTALLED Claude Status derives for sessions matching a selector,
for manual acceptance runs (e.g. a Desktop session driven by hand). Polls
`claude-status-ctl list --json` and writes sanitized transitions (id prefix, label, activity,
confidence, background count, detail, last event) as JSON lines. Read-only.

usage: watch_session.py OUT SECONDS (--id PREFIX | --newest-cwd-suffix NAME) [--interval 1]
"""
import argparse, json, os, subprocess, time
CTL = os.path.expanduser("~/Library/Application Support/ClaudeStatus/bin/claude-status-ctl")
ap = argparse.ArgumentParser()
ap.add_argument("out"); ap.add_argument("seconds", type=float)
ap.add_argument("--id", action="append", default=[])
ap.add_argument("--interval", type=float, default=1)
a = ap.parse_args()
last, end, t0 = {}, time.time() + a.seconds, time.time()
with open(a.out, "a", buffering=1) as f:
    while time.time() < end:
        try:
            d = json.loads(subprocess.run([CTL, "list", "--json"], capture_output=True, text=True, timeout=20).stdout)
        except Exception:
            time.sleep(a.interval); continue
        for s in d["sessions"]:
            if not any(s["id"].startswith(p) for p in a.id): continue
            k = (s["label"], s["activity"], s["confidence"], s.get("backgroundActive"), s["detail"])
            if last.get(s["id"]) != k:
                last[s["id"]] = k
                f.write(json.dumps({"t": time.strftime("%H:%M:%S"), "id": s["id"], "label": s["label"], "activity": s["activity"],
                                    "confidence": s["confidence"], "bg": s.get("backgroundActive"), "detail": s["detail"],
                                    "lastEvent": s["lastEvent"]}) + "\n")
        time.sleep(a.interval)
