#!/usr/bin/env python3
"""Decisions the watchdog is waiting on, shared with an optional dashboard.

logs/pending.json is a list of entries:
  id, ts, pid, lstart (process start time: proves the pid is still the SAME process),
  name, cmd, mb, class (free|service|trading), free_pct, swap_pct,
  state: dry-run | waiting | needs-you | killed | spared | expired
         waiting   = a dialog box is up right now
         needs-you = no dialog (bot/service, or dialog budget used up): decide in the hub
         dry-run   = the watchdog is in DRY_RUN; shown for information, not actionable

CLI (used by watchdog.sh):
  pending.py add PID NAME MB CLASS FREE SWAP STATE
  pending.py state PID STATE BY
"""
import json
import os
import subprocess
import sys
import time
from pathlib import Path

FILE = Path(__file__).resolve().parent / "logs" / "pending.json"
KEEP_SECS = 24 * 3600
OPEN_STATES = {"dry-run", "waiting", "needs-you"}


def read():
    try:
        return json.loads(FILE.read_text())
    except Exception:
        return []


def write(items):
    FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(items, indent=1))
    os.replace(tmp, FILE)


def ps_field(pid, field):
    try:
        return subprocess.run(["ps", "-o", field + "=", "-p", str(pid)],
                              capture_output=True, text=True, timeout=5).stdout.strip()
    except Exception:
        return ""


def lstart(pid):
    return ps_field(pid, "lstart")


def add(pid, name, mb, cls, free_pct, swap_pct, state):
    now = time.time()
    items = [e for e in read() if now - e.get("ts", 0) < KEEP_SECS]
    start = lstart(pid)
    for e in items:
        if str(e.get("pid")) == str(pid) and e.get("lstart") == start and e.get("state") in OPEN_STATES:
            e.update(ts=now, mb=int(float(mb)), free_pct=int(float(free_pct)),
                     swap_pct=int(float(swap_pct)), state=state)
            write(items)
            return e["id"]
    entry = {"id": f"{pid}-{int(now)}", "ts": now, "pid": int(pid), "lstart": start,
             "name": name, "cmd": ps_field(pid, "command")[:300], "mb": int(float(mb)),
             "class": cls, "free_pct": int(float(free_pct)), "swap_pct": int(float(swap_pct)),
             "state": state, "by": ""}
    items.append(entry)
    write(items)
    return entry["id"]


def set_state(pid, state, by=""):
    items = read()
    for e in items:
        if str(e.get("pid")) == str(pid) and e.get("state") in OPEN_STATES:
            e["state"], e["by"], e["resolved"] = state, by, time.time()
    write(items)


if __name__ == "__main__":
    a = sys.argv[1:]
    if a[:1] == ["add"] and len(a) == 8:
        print(add(*a[1:]))
    elif a[:1] == ["state"] and len(a) == 4:
        set_state(a[1], a[2], a[3])
    else:
        print(__doc__)
        sys.exit(2)
