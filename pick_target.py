#!/usr/bin/env python3
"""Choose what to kill under memory pressure. Prints: <MB> <pid> <class> <command>   (class: free|service|trading)

Reads `top -l 1 -o mem -stats pid,command,mem` on stdin. Prints nothing
killable as "0 0 none".

Three tiers, in order of how much we would regret killing them:

  NEVER        the OS, the database, the session issuing the kill. Killing any
               of these is worse than the hang they would prevent.
  TRADING      bots, brokers, market data. Protected *during market hours* —
               a bot holding a live position must not be killed at 10:30, but
               at 22:00 it is just another process.
  PREFERRED    an explicit order to sacrifice: Android Studio, Xcode, Chrome,
               Edge, Safari, then anything else non-essential. Big, reopenable,
               and no state is lost that the app will not restore itself.

Footprint, not RSS. With memory compressed, `ps rss` reported the largest
process on this machine at 157 MB while it held 7.4 GB; top's MEM column
includes compressed pages.

Market hours are deliberately generous — 04:00 to close+30m ET, weekdays,
every weekday treated as a trading day. Over-protecting costs one candidate
from a long list; under-protecting kills a bot with money at risk.
"""
import json
import os
import re
import subprocess
import sys
from datetime import datetime, time
from pathlib import Path

try:
    from zoneinfo import ZoneInfo
    ET = ZoneInfo("America/New_York")
except Exception:                                    # pragma: no cover
    ET = None

# {"default": "16:00", "overrides": {"2026-11-27": "13:00"}}; first file that exists wins.
_CLOSE_CANDIDATES = [
    Path(os.environ["MEMCAP_MARKET_CLOSE_JSON"]) if os.environ.get("MEMCAP_MARKET_CLOSE_JSON") else None,
    Path(__file__).resolve().parent / "market_close.json",
    Path.home() / "Projects/_shared/market_close.json",
]
MARKET_CLOSE_JSON = next((c for c in _CLOSE_CANDIDATES if c and c.exists()), Path(__file__).resolve().parent / "market_close.json")

# Never killed, at any hour, at any pressure.
NEVER = re.compile(
    r"WindowServer|kernel_task|launchd|loginwindow|Finder|SystemUIServer"
    r"|mds|mds_stores|backupd|coreaudiod|opendirectoryd|securityd"
    r"|postgres|redis-server|cloudflared|syncthing"
    r"|claude|Claude|memory-watchdog|watchdog",
    re.I,
)

# Protected while the market is open; fair game outside it.
_TRADING_BASE = (
    r"ThetaTerminal|IBController|ibgateway|IBGateway|IB Gateway|Trader Workstation|tws"
    r"|tastytrade|IBKR|ibkr"
)


def _local_patterns():
    """YOUR bot / service names: protected.local.txt beside this file, one regex per
    line, # for comments. Kept out of the code so a public copy carries no private names."""
    try:
        lines = (Path(__file__).resolve().parent / "protected.local.txt").read_text().splitlines()
    except OSError:
        return []
    return [ln.strip() for ln in lines if ln.strip() and not ln.strip().startswith("#")]


TRADING = re.compile("|".join([_TRADING_BASE] + _local_patterns()), re.I)

# Sacrifice order. Earlier entries go first regardless of size — an 8 GB
# Chrome is a better loss than a 2 GB build we would rather keep.
PREFERRED = [
    (r"Android Studio|studio\.sh|AndroidStudio|qemu-system|emulator", "Android Studio"),
    (r"Xcode|com\.apple\.dt\.Xcode|SourceKitService|swift-frontend|XCBBuildService", "Xcode"),
    (r"Google Chrome|Chrome Helper|chromedriver", "Chrome"),
    (r"Microsoft Edge|Edge Helper|msedge", "Edge"),
    (r"Safari|com\.apple\.WebKit|SafariBookmarks", "Safari"),
]

# A preferred-tier process smaller than this does not earn its place at the front
# of the queue. Without this floor a 200 MB Chrome helper outranked a 15 GB
# runaway python (2026-10-04): the helper was picked, fell under the minimum-kill
# size, and nothing was killed while the runaway kept growing.
MIN_TIER_MB = 1000

AGENTS_DIR = Path.home() / "Library/LaunchAgents"


def service_pids() -> dict:
    """pid -> launchd label for every running job that has a plist in
    ~/Library/LaunchAgents — i.e. the services YOU installed.

    `top` shows only the process name, so every Python service is just "Python"
    and every JVM is just "java"; a regex naming a bot can never match them.
    launchd knows exactly which pid belongs to which job, so ask it.
    Deliberately limited to the user's own LaunchAgents: app launches
    (Chrome, Xcode...) are launchd-managed too but are NOT services.
    """
    try:
        mine = {q.stem for q in AGENTS_DIR.glob("*.plist")}
        out = subprocess.run(["launchctl", "list"], capture_output=True, text=True, timeout=8).stdout
    except Exception:
        return {}
    pids = {}
    for line in out.splitlines()[1:]:
        f = line.split("\t")
        if len(f) == 3 and f[0].isdigit() and f[2].strip() in mine:
            pids[f[0]] = f[2].strip()
    return pids


def process_table() -> dict:
    """pid -> (ppid, full command line). top truncates and drops arguments."""
    try:
        out = subprocess.run(["ps", "-axo", "pid=,ppid=,command="], capture_output=True,
                             text=True, timeout=8).stdout
    except Exception:
        return {}
    table = {}
    for line in out.splitlines():
        f = line.split(None, 2)
        if len(f) == 3:
            table[f[0]] = (f[1], f[2])
    return table


UNIT = {"G": 1024.0, "M": 1.0, "K": 1 / 1024.0, "+": 1.0, "-": 1.0, "": 1 / 1048576.0}


def market_close_today(today) -> time:
    """Normal 16:00 unless _shared/market_close.json declares an early close."""
    try:
        data = json.loads(MARKET_CLOSE_JSON.read_text())
        hhmm = (data.get("overrides") or {}).get(today.isoformat()) or data.get("default", "16:00")
        h, m = (int(x) for x in hhmm.split(":"))
        return time(h, m)
    except Exception:
        return time(16, 0)


def in_market_hours(now=None) -> bool:
    if ET is None:
        return True                     # cannot tell the time zone: assume open
    now = now or datetime.now(ET)
    if now.weekday() >= 5:              # Sat/Sun
        return False
    close = market_close_today(now.date())
    # 04:00 covers pre-market positioning; +30m covers settlement and EOD writes.
    start = time(4, 0)
    end_min = close.hour * 60 + close.minute + 30
    cur_min = now.hour * 60 + now.minute
    return (cur_min >= start.hour * 60) and (cur_min <= end_min)


def parse(stream):
    for line in stream:
        f = line.split()
        if len(f) < 3 or not f[0].isdigit():
            continue
        pid, mem, cmd = f[0], f[-1], " ".join(f[1:-1])
        if not cmd:
            continue
        m = re.match(r"([\d.]+)([KMG+-]?)", mem)
        if not m:
            continue
        yield float(m.group(1)) * UNIT.get(m.group(2), 1.0), pid, cmd


def classify(pid, cmd, svc, table):
    """-> 'never' | 'trading' | 'service' | 'free'.  Full command line, not top's name."""
    ppid, full = table.get(pid, ("?", cmd))
    hay = cmd + " " + full
    if NEVER.search(cmd):
        return "never"
    if TRADING.search(hay):
        return "trading"
    # A launchd service (or a worker spawned by one, e.g. a uvicorn child).
    if pid in svc or ppid in svc:
        return "service"
    return "free"


def main(runaway_mb=None, svc=None, table=None) -> int:
    trading_hours = in_market_hours()
    svc = service_pids() if svc is None else svc
    table = process_table() if table is None else table

    tiers = {i: [] for i in range(len(PREFERRED) + 1)}   # +1 = "everything else"
    everything, services = [], []
    kinds = {}

    for mb, pid, cmd in parse(sys.stdin):
        kind = classify(pid, cmd, svc, table)
        kinds[pid] = kind
        if kind == "never":
            continue
        if kind in ("service", "trading"):
            if trading_hours:
                continue                                 # market open: bots and services are off the table
            services.append((mb, pid, cmd))              # after hours: reported, never auto-killed (see watchdog.sh)
            continue
        everything.append((mb, pid, cmd))
        for i, (pat, _label) in enumerate(PREFERRED):
            if re.search(pat, cmd, re.I):
                tiers[i].append((mb, pid, cmd))
                break
        else:
            tiers[len(PREFERRED)].append((mb, pid, cmd))

    if runaway_mb is not None:
        # Runaway mode targets only things nobody installed as a service: a script
        # someone launched by hand or a Claude session started. Services are never
        # judged a "runaway" — they are the processes this exists to protect.
        if everything:
            mb, pid, cmd = max(everything, key=lambda t: t[0])
            if mb >= runaway_mb:
                print(int(mb), pid, kinds.get(pid, "free"), cmd)
                return 0
        print(0, 0, "free", "none")
        return 0

    for i in range(len(PREFERRED)):
        if tiers[i]:
            mb, pid, cmd = max(tiers[i], key=lambda t: t[0])
            if mb >= MIN_TIER_MB:
                print(int(mb), pid, kinds.get(pid, "free"), cmd)
                return 0

    if everything:
        mb, pid, cmd = max(everything, key=lambda t: t[0])
        print(int(mb), pid, kinds.get(pid, "free"), cmd)
        return 0

    # Nothing unmanaged is left to sacrifice. A service is the last resort — its
    # KeepAlive restarts it — and only outside market hours (trading ones were
    # already filtered above while the market is open).
    if services:
        mb, pid, cmd = max(services, key=lambda t: t[0])
        print(int(mb), pid, kinds.get(pid, "free"), cmd)
        return 0

    print(0, 0, "free", "none")
    return 0


if __name__ == "__main__":
    if "--market-status" in sys.argv:                    # for testing/logging
        print("OPEN" if in_market_hours() else "CLOSED")
        sys.exit(0)
    if "--runaway" in sys.argv:                          # --runaway <MB>
        sys.exit(main(runaway_mb=float(sys.argv[sys.argv.index("--runaway") + 1])))
    sys.exit(main())
