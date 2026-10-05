#!/bin/bash
# selftest.sh — prove memcap.sh still works on this machine; writes
# logs/memcap_selftest.json for the Projects Hub "Memory Guard" tab.
# Allocates up to ~1.5 GB briefly. Safe to run any time.
HERE="$(cd "$(dirname "$0")" && pwd)"
M="${MEMCAP:-$HERE/memcap.sh}"; [[ -x "$M" ]] || M="$HOME/Projects/_shared/memcap.sh"
OUT="$HERE/logs/memcap_selftest.json"
mkdir -p "$HERE/logs"
results=(); pass=0; fail=0

check() {   # check NAME EXPECT_RC ACTUAL_RC [EXTRA_OK]
    if [[ "$2" == "$3" && "${4:-1}" == "1" ]]; then pass=$((pass+1)); st=pass; else fail=$((fail+1)); st=fail; fi
    results+=("{\"name\":\"$1\",\"expect\":\"$2\",\"got\":\"$3\",\"status\":\"$st\"}")
}

"$M" -n selftest-exit 1 -- bash -c 'exit 7' >/dev/null 2>&1;                 check "exit code passes through" 7 $?
out=$(echo hello | "$M" -n selftest-stdin 1 -- cat 2>/dev/null);              check "stdin passes through" 0 $? "$([[ "$out" == hello ]] && echo 1 || echo 0)"
"$M" >/dev/null 2>&1;                                       check "usage error" 2 $?

S=$SECONDS
"$M" -n selftest-single 0.5 -- python3 -c "
import time
b=bytearray(1200*1024*1024)
for i in range(0,len(b),4096): b[i]=1
time.sleep(30)" >/dev/null 2>&1;                            rc=$?
check "single process over cap is killed" 99 $rc "$(( SECONDS-S <= 8 ? 1 : 0 ))"

S=$SECONDS
"$M" -n selftest-tree 0.8 -- python3 "$HERE/selftest_tree.py" 4 300 >/dev/null 2>&1; rc=$?
check "tree of 4x300MB workers (sum over cap) is killed" 99 $rc "$(( SECONDS-S <= 10 ? 1 : 0 ))"

sleep 1
left=$(pgrep -f "selftest_tree.py|selftest-single" | grep -v $$ | wc -l | tr -d ' ')
check "no orphaned processes left" 0 "$left"

status=pass; (( fail )) && status=fail
printf '{"ts":"%s","status":"%s","passed":%d,"failed":%d,"checks":[%s]}\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S')" "$status" "$pass" "$fail" "$(IFS=,; echo "${results[*]}")" > "$OUT"
cat "$OUT"
(( fail == 0 ))
