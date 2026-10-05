#!/bin/bash
# memcap.sh — run a command under a memory cap macOS will not give you natively.
#
#   memcap.sh [-n NAME] [-i SECS] [-g GRACE] CAP_GB -- command [args...]
#
#   memcap.sh 6 -- python3 backtest.py
#   memcap.sh -n exits-backtest 6 -- python3 exits_backtest.py
#
# Why a wrapper: ulimit -v is silently ignored and setrlimit(RLIMIT_AS) is
# rejected on this Mac (tested 2026-09-02, see memory-watchdog/watchdog.sh), so
# the only option is to watch and act. This watches the command's WHOLE process
# tree every INTERVAL seconds — a multiprocessing Pool of 4 workers is measured
# as one, not as four small processes that each look innocent.
#
# Metric is `footprint` (includes compressed pages), not `ps rss`, which showed
# 157 MB for a process that really held 7.4 GB.
#
# Exit codes: the command's own code; 99 = killed for exceeding the cap;
#             2 = usage error.
# Resolution: a process can allocate several GB between two samples, so the cap
# is a guard rail, not a precision limit. Leave headroom (see CLAUDE.md §9).

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
# Log dir: $MEMCAP_LOGDIR; else logs/ beside a sibling watchdog.sh (the repo layout);
# else an existing ~/Projects/memory-watchdog/logs; else ~/.memcap/logs.
if   [[ -n "${MEMCAP_LOGDIR:-}" ]];                then LOGDIR="$MEMCAP_LOGDIR"
elif [[ -f "$HERE/watchdog.sh" ]];                 then LOGDIR="$HERE/logs"
elif [[ -d "$HOME/Projects/memory-watchdog/logs" ]]; then LOGDIR="$HOME/Projects/memory-watchdog/logs"
else LOGDIR="$HOME/.memcap/logs"; fi
EVENTS="$LOGDIR/memcap_events.jsonl"
MAX_EVENTS_BYTES=$((4 * 1024 * 1024))
NAME=""; INTERVAL=0.5; GRACE=5

usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

while getopts "n:i:g:h" opt; do
    case "$opt" in
        n) NAME="$OPTARG" ;;
        i) INTERVAL="$OPTARG" ;;
        g) GRACE="$OPTARG" ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

CAP_GB="${1:-}"; shift || true
[[ "${1:-}" == "--" ]] && shift
[[ -n "$CAP_GB" && $# -gt 0 ]] || usage
awk -v c="$CAP_GB" 'BEGIN{exit !(c ~ /^[0-9]+(\.[0-9]+)?$/ && c > 0)}' \
    || { echo "memcap: CAP_GB must be a positive number, got '$CAP_GB'" >&2; exit 2; }

CAP_BYTES=$(awk -v c="$CAP_GB" 'BEGIN{printf "%.0f", c*1073741824}')
[[ -n "$NAME" ]] || NAME=$(basename "$1")
CMDLINE=$(printf '%s ' "$@" | tr '\n\t\r' '   ' | sed 's/["\\]/ /g' | tr -s ' ' | cut -c1-200)

mkdir -p "$LOGDIR"
if [[ -f "$EVENTS" ]] && (( $(stat -f%z "$EVENTS" 2>/dev/null || echo 0) > MAX_EVENTS_BYTES )); then
    tail -n 2000 "$EVENTS" > "$EVENTS.tmp" && mv "$EVENTS.tmp" "$EVENTS"
fi

event() {   # event KIND [PEAK_GB] [EXIT]
    printf '{"ts":"%s","event":"%s","name":"%s","cap_gb":%s,"peak_gb":%s,"exit":%s,"pid":%s,"cmd":"%s"}\n' \
        "$(date '+%Y-%m-%dT%H:%M:%S')" "$1" "$(echo "$NAME" | sed 's/["\\]/ /g')" "$CAP_GB" \
        "${2:-0}" "${3:-null}" "${CHILD:-0}" "$CMDLINE" >> "$EVENTS"
}

descendants() {   # all descendant pids of $1, including $1, one per line
    ps -axo pid=,ppid= | awk -v root="$1" '
        { kids[$2] = kids[$2] " " $1 }
        END {
            n = 1; q[1] = root; seen[root] = 1
            for (i = 1; i <= n; i++) {
                print q[i]
                m = split(kids[q[i]], a, " ")
                for (j = 1; j <= m; j++) if (!(a[j] in seen)) { seen[a[j]] = 1; q[++n] = a[j] }
            }
        }'
}

FPJSON=$(mktemp -t memcap.XXXXXX)
tree_bytes() {   # total footprint of the tree rooted at $1, in bytes
    local args="" p
    for p in $(descendants "$1"); do args="$args -p $p"; done
    # shellcheck disable=SC2086
    footprint -j "$FPJSON" $args >/dev/null 2>&1
    plutil -extract "total footprint" raw -o - "$FPJSON" 2>/dev/null || echo 0
}

kill_tree() {
    local pids p
    pids=$(descendants "$1")
    for p in $pids; do kill -TERM "$p" 2>/dev/null; done
    local waited=0
    while (( waited < GRACE )); do
        sleep 1; waited=$((waited + 1))
        local alive=0
        for p in $pids; do kill -0 "$p" 2>/dev/null && alive=1; done
        (( alive )) || return 0
    done
    for p in $(descendants "$1"); do kill -KILL "$p" 2>/dev/null; done
}

exec 3<&0   # a backgrounded command otherwise gets /dev/null as stdin
"$@" <&3 &
CHILD=$!
exec 3<&-
cleanup() { rm -f "$FPJSON"; }
trap 'kill_tree "$CHILD"; cleanup; exit 143' INT TERM
event start 0

PEAK=0; KILLED=0
while kill -0 "$CHILD" 2>/dev/null; do
    BYTES=$(tree_bytes "$CHILD")
    [[ "$BYTES" =~ ^[0-9]+$ ]] || BYTES=0
    (( BYTES > PEAK )) && PEAK=$BYTES
    if (( BYTES > CAP_BYTES )); then
        GB=$(awk -v b="$BYTES" 'BEGIN{printf "%.2f", b/1073741824}')
        echo "memcap: '$NAME' used ${GB} GB, over the ${CAP_GB} GB cap — killing its process tree" >&2
        event kill "$GB"
        kill_tree "$CHILD"
        KILLED=1
        break
    fi
    sleep "$INTERVAL"
done

wait "$CHILD" 2>/dev/null; RC=$?
PEAK_GB=$(awk -v b="$PEAK" 'BEGIN{printf "%.2f", b/1073741824}')
cleanup
if (( KILLED )); then
    event killed_exit "$PEAK_GB" 99
    exit 99
fi
event finish "$PEAK_GB" "$RC"
exit "$RC"
