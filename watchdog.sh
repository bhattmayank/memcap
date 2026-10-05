#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# memory-watchdog.sh — warn before the machine becomes unresponsive, and kill a
# runaway only when it is that or a hang.
#
# Runs every 10s via launchd (com.memory-watchdog.monitor). It was 60s; on
# 2026-10-04 two runaway python3.12 jobs (15-16 GB on a 16 GB Mac) thrashed the
# machine for up to a minute before the next check. Cheap checks run every time;
# `top` only runs when memory is actually getting short.
# Logs to logs/watchdog.log next to this script (8 MB cap).
#
# Why this exists rather than a memory limit: macOS has no per-process cap.
# Both mechanisms were tested on this machine on 2026-09-02 —
#   ulimit -v            silently ignored (500 MB allocated under a 200 MB cap)
#   setrlimit(RLIMIT_AS) rejected by the kernel outright
# so "detect and act" is the only option available. On 2026-08-31 the machine
# took a watchdog-timeout panic (no checkins from watchdogd in 93s) after two
# duplicate TTS jobs pushed swap to 19.3 GB of 20 GB. This is the net for that.
#
# RSS is not the metric. With memory compressed, `ps rss` showed the largest
# process at 157 MB while it actually held 7.4 GB. Footprint comes from
# `top -stats mem`, which includes compressed pages.
# ─────────────────────────────────────────────────────────────────────────────

# Optional overrides live in watchdog.conf (e.g. DRY_RUN=1), so changing the mode
# never needs a launchd reload. A real environment variable still wins.
[[ -f "$(dirname "$0")/watchdog.conf" ]] && . "$(dirname "$0")/watchdog.conf"

LOG="$(dirname "$0")/logs/watchdog.log"
MAX_LOG_BYTES=$((8 * 1024 * 1024))
mkdir -p "$(dirname "$LOG")"

# Overridable from the environment so the thresholds can be exercised without
# editing the file — a watchdog that cannot be tested is a watchdog nobody
# trusts. DRY_RUN=1 reports what it would kill without killing it.
WARN_FREE_PCT=${WARN_FREE_PCT:-15}   # notify below this much free memory
CRIT_FREE_PCT=${CRIT_FREE_PCT:-8}    # consider killing below this
WARN_SWAP_PCT=${WARN_SWAP_PCT:-70}   # notify above this much swap used
CRIT_SWAP_PCT=${CRIT_SWAP_PCT:-90}   # consider killing above this
MIN_KILL_MB=${MIN_KILL_MB:-2000}     # below this, killing would not buy enough
GRACE_SECS=${GRACE_SECS:-8}          # SIGTERM, then SIGKILL after this
DRY_RUN=${DRY_RUN:-0}
# --- added 2026-10-05 -------------------------------------------------------
PROC_CAP_MB=${PROC_CAP_MB:-8000}               # one process this big ...
RUNAWAY_FREE_PCT=${RUNAWAY_FREE_PCT:-50}       # ... while free memory is at/below this = runaway: kill early
SWAP_NEEDS_FREE_PCT=${SWAP_NEEDS_FREE_PCT:-50} # high swap alone is not an emergency while RAM is plentiful
WARN_REPEAT_SECS=${WARN_REPEAT_SECS:-60}       # throttle WARN log lines + notifications
METRICS_EVERY_SECS=${METRICS_EVERY_SECS:-55}   # keep the metrics.csv cadence at ~1/min
CONFIRM_KILL=${CONFIRM_KILL:-1}                # ask in a dialog box before killing anything
CONFIRM_TIMEOUT_SECS=${CONFIRM_TIMEOUT_SECS:-60}
CONFIRM_ON_TIMEOUT=${CONFIRM_ON_TIMEOUT:-kill} # no answer: kill an unmanaged runaway (kill|spare). Services/trading are ALWAYS spared.
SPARE_SECS=${SPARE_SECS:-1800}                 # after "Spare it", do not ask about that pid again for this long
# --- anti-overwhelm + bot protection (2026-10-05) ----------------------------
PROTECT_BOTS_ALWAYS=${PROTECT_BOTS_ALWAYS:-1}  # 1 = trading bots and launchd services are NEVER auto-killed, any hour
DIALOG_MAX_PER_HOUR=${DIALOG_MAX_PER_HOUR:-3}  # hard ceiling on dialog boxes; beyond it the hub is the only prompt
MAX_ASKS_PER_PID=${MAX_ASKS_PER_PID:-2}        # one process can interrupt you at most this many times in its life
HUB_URL=${HUB_URL:-}                           # optional dashboard that lists logs/pending.json (shown in banners)
NOTIFY_PENDING_EVERY_SECS=${NOTIFY_PENDING_EVERY_SECS:-600}  # quiet banner for "decide in the hub"
CRIT_LOG_EVERY_SECS=${CRIT_LOG_EVERY_SECS:-60} # 10s polling must not log the same incident 6x a minute
MARKET_PROC_CAP_MB=${MARKET_PROC_CAP_MB:-6000} # while the market is open an unmanaged hog is dealt with earlier ...
MARKET_RUNAWAY_FREE_PCT=${MARKET_RUNAWAY_FREE_PCT:-60}  # ... so the bots keep their headroom

[[ -f "$LOG" ]] && (( $(stat -f%z "$LOG" 2>/dev/null || echo 0) > MAX_LOG_BYTES )) && {
    tail -n 10000 "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"; }

ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" >> "$LOG"; }
# confirm_kill CLASS CMD PID MB -> 0 = go ahead and kill, 1 = spare it, 2 = no dialog
# (budget used up) so the decision waits in the hub instead.
# A dialog gives a human the last word. Nobody at the keyboard (3am) must not mean
# a hung machine, so an unmanaged runaway is killed on timeout — but a launchd
# service or trading process is never killed without an explicit "Kill it".
confirm_kill() {
    [[ "$CONFIRM_KILL" == "1" ]] || return 0
    local cls="$1" cmd="$2" pid="$3" mb="$4" on_timeout="$CONFIRM_ON_TIMEOUT"
    [[ "$cls" == "free" ]] || on_timeout=spare
    local spared asked n_asked; spared="$(dirname "$0")/logs/.spared_${pid}"; asked="$(dirname "$0")/logs/.asked_${pid}"
    if [[ -f "$spared" ]] && (( $(date +%s) - $(stat -f%m "$spared" 2>/dev/null || echo 0) < SPARE_SECS )); then
        log "SPARED (you said so earlier, not asking again for ${SPARE_SECS}s): ${cmd} pid=${pid}"
        return 1
    fi
    # Not overwhelming you: a process may interrupt you MAX_ASKS_PER_PID times, and
    # at most DIALOG_MAX_PER_HOUR dialogs appear in any hour. Past either limit the
    # question moves to the hub, which waits quietly.
    n_asked=$(cat "$asked" 2>/dev/null || echo 0)
    if (( n_asked >= MAX_ASKS_PER_PID )); then
        log "no dialog: pid ${pid} already asked ${n_asked}x — left to the hub"; return 2
    fi
    if ! dialog_budget_ok; then
        log "no dialog: ${DIALOG_MAX_PER_HOUR}/hour budget used — left to the hub (${cmd} pid=${pid})"; return 2
    fi
    echo $((n_asked + 1)) > "$asked"; date +%s >> "$(dirname "$0")/logs/dialog_history"

    # Everything a human needs to decide: which process, how big, how old, who
    # started it, and what happens if nobody answers.
    local ppid etime full user label kind
    read -r ppid etime user < <(ps -o ppid=,etime=,user= -p "$pid" 2>/dev/null)
    full=$(ps -o command= -p "$pid" 2>/dev/null | cut -c1-230)
    label=$(launchctl list 2>/dev/null | awk -v p="$pid" '$1==p {print $3; exit}')
    case "$cls" in
        free)    kind="Unmanaged - started by hand or by a script, not a launchd service" ;;
        service) kind="launchd SERVICE ${label:+($label)} - launchd will restart it" ;;
        trading) kind="TRADING process ${label:+($label)}" ;;
        *)       kind="$cls" ;;
    esac
    local outcome="killed"; [[ "$on_timeout" == "spare" ]] && outcome="left alone"
    local msg="MEMORY IS CRITICALLY LOW
Free RAM ${free_pct}%   |   Swap used ${swap_pct}%

PROCESS TO CLOSE
Name:      ${cmd}
PID:       ${pid}   (parent ${ppid:-?})
Memory:    ${mb} MB
Running:   ${etime:-?}   as ${user:-?}
Type:      ${kind}
Command:   ${full:-unknown}

Kill it?
If you do nothing for ${CONFIRM_TIMEOUT_SECS} seconds it will be ${outcome}."
    msg=$(printf '%s' "$msg" | tr -d '"\\')
    local reply
    reply=$(MSG="$msg" T="$CONFIRM_TIMEOUT_SECS" osascript \
        -e 'set m to system attribute "MSG"' \
        -e 'set t to (system attribute "T") as integer' \
        -e 'tell application "System Events"' \
        -e 'activate' \
        -e 'set r to display dialog m with title "Memory Watchdog" buttons {"Spare it", "Kill it"} default button "Spare it" with icon caution giving up after t' \
        -e 'return (button returned of r) & "|" & (gave up of r)' \
        -e 'end tell' 2>/dev/null)
    if [[ -z "$reply" ]]; then
        log "no dialog possible (no GUI session?) — policy: $on_timeout"
        [[ "$on_timeout" == "kill" ]]; return
    fi
    if [[ "${reply##*|}" == "true" ]]; then
        log "no answer in ${CONFIRM_TIMEOUT_SECS}s — policy: ${on_timeout} (${cmd} pid=${pid})"
        [[ "$on_timeout" == "kill" ]]; return
    fi
    if [[ "${reply%%|*}" == "Kill it" ]]; then
        log "you chose: Kill it (${cmd} pid=${pid})"; return 0
    fi
    touch "$spared"; log "you chose: Spare it (${cmd} pid=${pid})"; return 1
}

pend() { python3 "$(dirname "$0")/pending.py" "$@" >/dev/null 2>&1; }

notify_pending() {   # quiet, rate-limited: "there is something to decide in the hub"
    local st; st="$(dirname "$0")/logs/.last_pending_notify"
    if (( $(date +%s) - $(stat -f%m "$st" 2>/dev/null || echo 0) >= NOTIFY_PENDING_EVERY_SECS )); then
        osascript -e "display notification \"$1\" with title \"Memory Watchdog\"" 2>/dev/null
        touch "$st"
    fi
}

dialog_budget_ok() {   # 0 = a dialog box may be shown right now
    local hist; hist="$(dirname "$0")/logs/dialog_history"
    [[ -f "$hist" ]] || : > "$hist"
    awk -v n="$(date +%s)" '$1 > n-3600' "$hist" > "$hist.tmp" && mv "$hist.tmp" "$hist"
    (( $(wc -l < "$hist") < DIALOG_MAX_PER_HOUR ))
}

notify() {
    osascript -e "display notification \"$2\" with title \"$1\" sound name \"Basso\"" 2>/dev/null
}

free_pct=$(memory_pressure 2>/dev/null | awk -F': ' '/free percentage/ {gsub(/%/,"",$2); print $2+0}')
read -r swap_used swap_total < <(sysctl -n vm.swapusage 2>/dev/null | awk '
    {gsub(/M/,""); for(i=1;i<=NF;i++){if($i=="used")u=$(i+2); if($i=="total")t=$(i+2)} print u, t}')
swap_pct=0
[[ -n "${swap_total:-}" && "${swap_total%%.*}" -gt 0 ]] && \
    swap_pct=$(awk -v u="$swap_used" -v t="$swap_total" 'BEGIN{printf "%d", (u/t)*100}')

[[ -z "$free_pct" ]] && { log "could not read memory pressure — skipping"; exit 0; }

# Swap stays high for hours after a spike even when RAM is back to 75-80% free;
# the old rule logged WARN every minute and reached CRITICAL at 83% free (see
# 2026-10-04 21:48 and 22:59). Swap now only counts while RAM is also short.
crit=false; warn=false; runaway=false
if (( free_pct <= CRIT_FREE_PCT )) || { (( swap_pct >= CRIT_SWAP_PCT )) && (( free_pct <= SWAP_NEEDS_FREE_PCT )); }; then crit=true; fi
if (( free_pct <= WARN_FREE_PCT )) || { (( swap_pct >= WARN_SWAP_PCT )) && (( free_pct <= SWAP_NEEDS_FREE_PCT )); }; then warn=true; fi
# Market open = the bots have priority: an unmanaged hog is dealt with at a lower
# size and while more RAM is still free, so it is gone before the bots feel it.
market=CLOSED
if (( free_pct <= MARKET_RUNAWAY_FREE_PCT )); then
    market=$(python3 "$(dirname "$0")/pick_target.py" --market-status 2>/dev/null || echo CLOSED)
fi
if [[ "$market" == "OPEN" ]]; then cap_mb=$MARKET_PROC_CAP_MB; rfree=$MARKET_RUNAWAY_FREE_PCT
else cap_mb=$PROC_CAP_MB; rfree=$RUNAWAY_FREE_PCT; fi
runaway_check=false; (( free_pct <= rfree )) && runaway_check=true

# A metrics row every run, healthy or not. Without history there is no way to
# tell a spike that resolved itself from a leak that is still climbing.
METRICS="$(dirname "$0")/logs/metrics.csv"
last_metric=$(stat -f%m "$METRICS" 2>/dev/null || echo 0)
[[ -f "$METRICS" ]] || echo "ts,free_pct,swap_used_mb,swap_total_mb,swap_pct,app_gb,wired_gb,compressed_gb,market" > "$METRICS"
if (( $(date +%s) - last_metric >= METRICS_EVERY_SECS )); then
    read -r app_gb wired_gb comp_gb < <(vm_stat 2>/dev/null | awk '
      /Pages active/{a=$3} /Pages wired/{w=$4} /occupied by compressor/{c=$5}
      END{gsub(/\./,"",a); gsub(/\./,"",w); gsub(/\./,"",c);
          printf "%.2f %.2f %.2f", a*16384/1e9, w*16384/1e9, c*16384/1e9}')
    mkt=$(python3 "$(dirname "$0")/pick_target.py" --market-status 2>/dev/null || echo "?")
    echo "$(ts),${free_pct},${swap_used},${swap_total},${swap_pct},${app_gb},${wired_gb},${comp_gb},${mkt}" >> "$METRICS"

    # Keep the metrics file bounded: 60s cadence is ~1440 rows/day, so 20k rows is
    # about two weeks of history.
    if (( $(wc -l < "$METRICS") > 20000 )); then
        { head -1 "$METRICS"; tail -n 15000 "$METRICS"; } > "${METRICS}.tmp" && mv "${METRICS}.tmp" "$METRICS"
    fi
fi

$crit || $warn || $runaway_check || exit 0   # healthy: metrics only, no log noise, no alert

# Largest process by real footprint (compressed included), excluding protected.
# Parsing lives in pick_target.py — as a shell `case` inside a pipeline it was a
# syntax error, which would have silently disabled this whole check.
top_out=$(top -l 1 -n 40 -o mem -stats pid,command,mem 2>/dev/null)
top_line=$(echo "$top_out" | python3 "$(dirname "$0")/pick_target.py" 2>/dev/null)

# Runaway rule: one process >= PROC_CAP_MB while RAM is half gone is the problem
# regardless of which app we would rather lose, so pick the biggest, not the
# most expendable. Acts before CRITICAL, i.e. before the machine starts thrashing.
if ! $crit && $runaway_check; then
    big_line=$(echo "$top_out" | python3 "$(dirname "$0")/pick_target.py" --runaway "$cap_mb" 2>/dev/null)
    read -r big_mb _ _ _ <<< "${big_line:-0 0 free none}"
    if [[ "${big_mb:-0}" -ge "$cap_mb" ]]; then
        runaway=true; crit=true; top_line="$big_line"
    fi
fi
$crit || $warn || exit 0

read -r top_mb top_pid top_class top_cmd <<< "${top_line:-0 0 free none}"

if $crit; then
    tag=CRITICAL; $runaway && tag="RUNAWAY(>=${cap_mb}MB,market=${market})"
    # 10s polling would otherwise write the same incident six times a minute.
    cstamp="$(dirname "$0")/logs/.last_crit"; logged_now=false
    if [[ "$(cut -d' ' -f1 "$cstamp" 2>/dev/null)" != "$top_pid" ]] || \
       (( $(date +%s) - $(stat -f%m "$cstamp" 2>/dev/null || echo 0) >= CRIT_LOG_EVERY_SECS )); then
        log "${tag} free=${free_pct}% swap=${swap_pct}% | largest killable: ${top_cmd} pid=${top_pid} ${top_mb}MB class=${top_class}"
        echo "$top_pid $(date +%s)" > "$cstamp"; logged_now=true
    fi
    if [[ "${top_mb:-0}" -ge "$MIN_KILL_MB" && "${top_pid:-0}" -gt 1 ]]; then
        # Trading bots and launchd services are never killed automatically, at any
        # hour. They are surfaced in the hub; a person kills them there, or doesn't.
        if [[ "$top_class" != "free" && "$PROTECT_BOTS_ALWAYS" == "1" ]]; then
            pend add "$top_pid" "$top_cmd" "$top_mb" "$top_class" "$free_pct" "$swap_pct" \
                "$([[ "$DRY_RUN" == "1" ]] && echo dry-run || echo needs-you)"
            $logged_now && log "PROTECTED ${top_class}: ${top_cmd} (pid ${top_pid}, ${top_mb}MB) is the largest candidate — NOT auto-killed; decide in the hub"
            [[ "$DRY_RUN" == "1" ]] || notify_pending "Memory is low. ${top_cmd} (${top_class}, ${top_mb}MB) needs your decision in the hub: ${HUB_URL:-see logs/pending.json}"
            exit 0
        fi
        if [[ "$DRY_RUN" == "1" ]]; then
            pend add "$top_pid" "$top_cmd" "$top_mb" "$top_class" "$free_pct" "$swap_pct" dry-run
            $logged_now && \
                log "DRY RUN — would ask, then kill ${top_cmd} (pid ${top_pid}, ${top_mb}MB, class=${top_class})"
            exit 0
        fi
        pend add "$top_pid" "$top_cmd" "$top_mb" "$top_class" "$free_pct" "$swap_pct" waiting
        confirm_kill "$top_class" "$top_cmd" "$top_pid" "$top_mb"; rc=$?
        if (( rc == 2 )); then
            pend state "$top_pid" needs-you watchdog
            notify_pending "Memory is low. ${top_cmd} (pid ${top_pid}, ${top_mb}MB) needs your decision in the hub: ${HUB_URL:-see logs/pending.json}"
            exit 0
        elif (( rc != 0 )); then
            pend state "$top_pid" spared dialog
            exit 0
        fi
        # Ask before insisting: SIGTERM, GRACE_SECS to flush and exit, SIGKILL
        # only if it ignored us. A browser or IDE asked politely saves its
        # session; SIGKILLed it loses the tabs and the in-flight build.
        if kill -TERM "$top_pid" 2>/dev/null; then
            log "SIGTERM -> ${top_cmd} (pid ${top_pid}, ${top_mb}MB) — ${GRACE_SECS}s grace"
            notify "Memory Watchdog" "Low memory: closing ${top_cmd} (${top_mb}MB), ${GRACE_SECS}s to save"
            for _ in $(seq 1 "$GRACE_SECS"); do
                kill -0 "$top_pid" 2>/dev/null || break
                sleep 1
            done
            if kill -0 "$top_pid" 2>/dev/null; then
                kill -9 "$top_pid" 2>/dev/null \
                    && log "KILLED ${top_cmd} (pid ${top_pid}, ${top_mb}MB) — SIGKILL, ignored SIGTERM" \
                    || log "SIGKILL failed for pid ${top_pid}"
            else
                log "KILLED ${top_cmd} (pid ${top_pid}, ${top_mb}MB) — exited cleanly on SIGTERM"
            fi
            pend state "$top_pid" killed watchdog
        else
            log "could not signal pid ${top_pid} (${top_cmd})"
        fi
    else
        log "nothing safe and large enough to kill (largest ${top_mb}MB < ${MIN_KILL_MB}MB)"
        notify "Memory Watchdog" "CRITICAL: free ${free_pct}%, swap ${swap_pct}% — nothing safe to kill"
    fi
else
    stamp="$(dirname "$0")/logs/.last_warn"
    last_w=$(stat -f%m "$stamp" 2>/dev/null || echo 0)
    if (( $(date +%s) - last_w >= WARN_REPEAT_SECS )); then
        log "WARN free=${free_pct}% swap=${swap_pct}% | largest: ${top_cmd} ${top_mb}MB"
        notify "Memory Watchdog" "Low memory: ${free_pct}% free, swap ${swap_pct}% — largest ${top_cmd} ${top_mb}MB"
        touch "$stamp"
    fi
fi
