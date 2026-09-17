#!/usr/bin/env bash
# Assert the three ABI facts required by the pgrx fork's `yb-pg15` feature.
#
#   probe-yb-abi.sh [pg-include-server-dir]
#
# Compilation proves that the fork applies, but not that a still-compiling adaptation matches
# changed YugabyteDB headers. Assert the assumed header shape before compiling the extension and
# name the mismatched symbol on failure.
set -euo pipefail

INC="${1:-/home/yugabyte/postgres/include/server}"
[ -d "$INC" ] || { echo "probe-yb-abi: no server include dir at $INC" >&2; exit 2; }

fail=0
note() { printf '  \033[32mok\033[0m    %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }

echo "probe-yb-abi: checking YugabyteDB's PG15 headers under $INC"

# ---------------------------------------------------------------------------------------------
# 1. The thread-local memory-context global.
#
# YB's YSQL is multi-threaded, so it renames the process-global CurrentMemoryContext to a
# thread-local YbCurrentMemoryContext. pgrx hardcodes the upstream name in port.rs
# (MemoryContextSwitchTo) and ffi.rs (error-path restores); one crate-root alias covers every site.
#
# BOTH halves are asserted. "YbCurrentMemoryContext exists" alone would still hold on a future
# release that restored the upstream name beside it -- and then the alias would silently shadow a
# real process-global with a thread-local one, which is the bug this whole shim exists to avoid.
# ---------------------------------------------------------------------------------------------
if grep -rqE '\bYbCurrentMemoryContext\b' "$INC"/utils/palloc.h "$INC"/nodes/memnodes.h 2>/dev/null; then
    note "YbCurrentMemoryContext is declared (the thread-local the alias points at)"
else
    bad "YbCurrentMemoryContext is GONE from palloc.h/memnodes.h -- shim patch 1 (the CurrentMemoryContext alias) has no target"
fi
if grep -qE '^[[:space:]]*extern[^;]*[^a-zA-Z_]CurrentMemoryContext\b' "$INC"/utils/palloc.h 2>/dev/null; then
    bad "an upstream-style CurrentMemoryContext is declared again -- the alias would SHADOW it; re-derive the shim before trusting a build"
else
    note "no upstream CurrentMemoryContext extern (so pgrx's alias is unambiguous)"
fi

# ---------------------------------------------------------------------------------------------
# 2. index_build_range_scan's arity.
#
# YB's table-AM callback takes 14 arguments where upstream takes 11: +YbBackfillInfo*,
# +YbPgExecOutParam*, +YbIndexBuildCallback. pgrx's generated caller passes 11 and the shim adds
# three. Counting the parameters makes "still 14" a measurement rather than a memory.
# ---------------------------------------------------------------------------------------------
AM="$INC/access/tableam.h"
if [ -f "$AM" ]; then
    if arity=$(python3 - "$AM" <<'PY'
import re, sys
src = open(sys.argv[1], encoding='utf-8', errors='replace').read()
src = re.sub(r'/\*.*?\*/', ' ', src, flags=re.S)          # comments would hide commas
i = src.find('index_build_range_scan')
if i < 0:
    sys.exit('index_build_range_scan not found')
i = src.index('(', i)
depth, args, cur = 0, [], ''
for ch in src[i:]:
    if ch == '(':
        depth += 1
        if depth == 1:
            continue
    elif ch == ')':
        depth -= 1
        if depth == 0:
            break
    if depth == 1 and ch == ',':                          # only TOP-level commas separate params
        args.append(cur); cur = ''
    else:
        cur += ch
args.append(cur)
print(len([a for a in args if a.strip()]))
PY
    ); then
        if [ "$arity" -eq 14 ]; then
            note "index_build_range_scan takes 14 parameters (upstream takes 11; the shim supplies 3)"
        else
            bad "index_build_range_scan takes $arity parameters, expected 14 -- shim patch 2 passes the wrong number of arguments"
        fi
    else
        bad "could not read index_build_range_scan's declaration out of $AM"
    fi
else
    bad "no $AM -- cannot check index_build_range_scan's arity"
fi

# ---------------------------------------------------------------------------------------------
# 3. BackgroundWorker's extra field.
#
# YB adds `char bgw_oom_score_adj[BGW_MAXLEN]`. pgrx's BackgroundWorkerBuilder does not know about
# it, so the struct literal it builds is missing a field and fails to compile; the shim zeroes it.
# kmoney registers no background worker, but pgrx's bgworkers module is compiled regardless.
# ---------------------------------------------------------------------------------------------
BGW="$INC/postmaster/bgworker.h"
if [ -f "$BGW" ] && grep -qE '\bbgw_oom_score_adj\b' "$BGW"; then
    note "BackgroundWorker carries bgw_oom_score_adj (the field the shim zeroes)"
else
    bad "BackgroundWorker no longer carries bgw_oom_score_adj -- shim patch 3 would add a field that does not exist"
fi

echo
if [ "$fail" -gt 0 ]; then
    cat >&2 <<'EOF'
probe-yb-abi: FAILED.

This image's headers no longer match the ABI the pgrx fork's `yb-pg15` feature was derived and
validated against. Do NOT relax this probe to get a build through: an adaptation that no longer
matches the headers can still COMPILE, and then it is silently the wrong adaptation.

The procedure for adopting a new YugabyteDB version is in kamu-money-pg/yb/RUNBOOK.md.
EOF
    exit 1
fi
echo "probe-yb-abi: OK -- all three shimmed symbols still have the expected shape"
