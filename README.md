# memcap

macOS has no way to cap a process's memory. `ulimit -v` is silently ignored and
`setrlimit(RLIMIT_AS)` is rejected by the kernel (both tested on Apple Silicon, macOS 26/27), so the
only protection against a runaway script is to **watch it and act**. This repo is two small layers
that do exactly that, in plain bash + a little Python, no dependencies.

| Layer | What it does |
|---|---|
| **`memcap.sh`** | Runs one command and kills its **whole process tree** if it passes a cap you choose. You opt in per command. |
| **`watchdog.sh`** | A system-wide safety net for everything you did *not* wrap. Warns, then picks the right culprit under memory pressure, and asks you before killing. |

Born from two 15-16 GB Python research jobs on a 16 GB Mac that thrashed the machine for a minute
each before anything noticed.

## memcap.sh

```bash
./memcap.sh 6 -- python3 backtest.py                    # kill the tree if it passes 6 GB
./memcap.sh -n my-backtest 6 -- python3 backtest.py     # name it in the event log
```

* The cap applies to the **sum over the whole process tree**. A `multiprocessing.Pool(4)` is measured
  as one, not as four small processes that each look innocent.
* The metric is `footprint` (it includes compressed pages), **not** `ps rss`. With memory compression
  on, `ps rss` showed 157 MB for a process that really held 7.4 GB.
* Exit code **99** = killed for exceeding the cap; otherwise the command's own exit code. Signals and
  stdin pass through; the tree is SIGTERMed, then SIGKILLed after a grace period.
* It is a **guard rail, not a precision limit**: it samples every 0.5 s, and a process can allocate
  several GB between samples. Leave headroom.
* Every run appends a JSON line (`start` / `finish` / `kill`, with the peak footprint) to
  `logs/memcap_events.jsonl`, so you can tune caps from real peaks. Log dir: `$MEMCAP_LOGDIR`, else
  `logs/` beside `watchdog.sh`, else `~/.memcap/logs`.

`./selftest.sh` proves it still works: exit-code and stdin passthrough, a single process over the cap,
a worker tree whose members are each under the cap but whose sum is over, and no orphans left behind.

## watchdog.sh

Runs every 10 s under launchd. Cheap checks (`memory_pressure`, swap) run every time; `top` only runs
when RAM is actually getting short.

**It decides *who* by classifying every process**, using the full command line and launchd (not
`top`'s name column, which shows every Python service as just "Python"):

| Class | Examples | Treatment |
|---|---|---|
| **never** | the OS, Finder, databases, your terminal/agent | never touched |
| **trading** | brokers, bots, market-data services (built-in list + `protected.local.txt`) | never auto-killed at any hour; during market hours not even a candidate |
| **service** | any job installed in `~/Library/LaunchAgents` (found via `launchctl`) | never judged a runaway; only ever *reported* |
| **free** | something you or a script launched by hand | the only class that can be auto-killed |

**Rules**

* **Runaway rule**: one *free* process >= 8000 MB while free RAM <= 50% is dealt with early, before the
  machine thrashes (>= 6000 MB / <= 60% while the market is open, so the bots keep their headroom).
* **Critical rule**: free RAM <= 8% (or swap >= 90% *and* RAM short). High swap alone is not an
  emergency; it stays high for hours after a spike.
* **Confirm before killing**: a dialog shows name, PID, parent, memory, run time, user, type and the full
  command, with "Spare it" as the default button. No answer in 60 s: a free process is killed (a
  service/bot never is). Limits so it can't nag: one dialog at a time, at most 3 an hour, 2 per process,
  and "Spare it" silences that PID for 30 minutes. Past a limit the question moves to
  `logs/pending.json` for a dashboard to show.
* **Picker fix worth knowing about**: a naive "sacrifice the browser first" tier order will pick a 200 MB
  Chrome helper over a 15 GB runaway, then refuse to act because 200 MB is too small. Preferred
  victims here must be >= 1000 MB to jump the queue.
* Market hours: weekdays 04:00 to 30 min after the close, America/New_York, with optional early closes in
  `market_close.json`. Every weekday is treated as a trading day (over-protecting is cheap).

**Install**

```bash
cp watchdog.conf.example watchdog.conf             # starts in DRY_RUN=1: logs only, kills nothing
cp protected.local.txt.example protected.local.txt # your own bot/service names (gitignored)
sed "s|__INSTALL_DIR__|$PWD|g" com.memcap.watchdog.plist.template > ~/Library/LaunchAgents/com.memcap.watchdog.plist
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.memcap.watchdog.plist
tail -f logs/watchdog.log
```

Run it in `DRY_RUN=1` for a day and read `logs/watchdog.log` (`DRY RUN - would ask, then kill ...`,
`PROTECTED ...`). When the targets look right, set `DRY_RUN=0` in `watchdog.conf` (no reload needed).
Test the thresholds without a real spike: `PROC_CAP_MB=300 RUNAWAY_FREE_PCT=100 DRY_RUN=1 bash watchdog.sh`.

**Pending decisions** are written to `logs/pending.json` (pid, start time, name, command, MB, class,
state). Anything can read it; a dashboard just needs a "kill" button that re-checks the PID's start time
(so a recycled PID is never killed) and refuses the *never* class.

## Files

`memcap.sh` wrapper - `selftest.sh` / `selftest_tree.py` tests - `watchdog.sh` the net - `pick_target.py`
classification and victim choice - `pending.py` shared decision file - `*.example` config templates.

## Limits

macOS only (`footprint`, `memory_pressure`, `osascript`, `launchctl`). Apple Silicon, 16 GB, macOS 27
is where it was exercised. Detect-and-act means the thing it protects you from can still briefly
exceed the cap; it bounds the damage, it does not prevent it.
