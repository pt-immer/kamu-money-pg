#!/usr/bin/env bash
# `kmoney` versus `numeric(36,18)` ON YUGABYTEDB -- arithmetic, render, parse, storage.
# NEVER a gate.
#
#   kamu-money-pg/bench/run-bench-sql-yb.sh [rows] [passes] [tag]
#
# WHY THIS EXISTS SEPARATELY FROM `just bench-pg`. The same fixture, on the engine this actually
# deploys to. It is not a formality:
#
#   - Stock PostgreSQL scans a local heap; YugabyteDB scans DocDB over the network, so their scan
#     floors differ materially.
#   - Whether that floor SWAMPS the kmoney-versus-numeric difference is itself the answer a
#     schema designer needs. If it does, the type choice is free at the storage layer and should
#     be made on correctness alone. If it does not, the per-row figures carry over. Either way
#     the answer is a measurement, not a deduction -- "the direction is obvious" is how a
#     magnitude nobody checked becomes a design input.
#
# THE DEPLOYABLE NODE IMAGE, not a probe image: `node-image.sh` builds `--target node`, the same
# artifact the release gate certifies. Nothing here needs `boundary-probe`, and it must not have
# it -- a benchmark of the shipped extension has to be a benchmark OF THE SHIPPED EXTENSION.
#
# EXPECT A REFUSAL TO BE POSSIBLE. The fixture aborts rather than print a summary when the floor
# spread exceeds 1.5, and DocDB's variance is exactly the thing that trips it. That is a result:
# it says this host cannot resolve the difference today. Do not lower the threshold to make a
# table appear.
set -euo pipefail
cd "$(dirname "$0")/../.."   # repo root

# shellcheck source=kamu-money-pg/bench/numa.sh
source "$(dirname "$0")/numa.sh"
# Empty when unpinned; the `+` form keeps `set -u` happy with an empty array.
read -r -a NUMA_ARGS <<< "$(numa_docker_args)"

# shellcheck source=kamu-money-pg/yb/workspace-lock.sh
source "$(dirname "$0")/../yb/workspace-lock.sh"
workspace_lock "$(basename "$0")" || exit 1

ROWS="${1:-100000}"
PASSES="${2:-5}"
TAG_ARG="${3:-}"
# WHICH FIXTURE. Both scripts take the same `-v rows`/`-v passes` and both boot the same
# deployable node image, so they share a runner rather than growing a second copy of the
# readiness loop, the lock and the identity resolution.
SQL_FILE="${4:-kamu-money-pg/bench/sql-cost.sql}"
[ -f "$SQL_FILE" ] || { echo "bench-sql-yb: no such fixture: $SQL_FILE" >&2; exit 2; }

# DIGITS AND `>= 1`, not digits alone. `0` is all digits and non-empty, so it passed a check that
# said "positive integer" and then produced a run with no rows or no passes -- an empty sample set
# whose summary table is a set of nulls, or a zero-row table whose per-row divisions are by zero.
# Either way the transcript looks like a measurement.
case "$ROWS"   in ''|*[!0-9]*) echo "rows must be a positive integer, got '$ROWS'" >&2; exit 2 ;; esac
case "$PASSES" in ''|*[!0-9]*) echo "passes must be a positive integer, got '$PASSES'" >&2; exit 2 ;; esac
[ "$ROWS"   -ge 1 ] || { echo "rows must be >= 1, got '$ROWS'" >&2; exit 2; }
[ "$PASSES" -ge 1 ] || { echo "passes must be >= 1, got '$PASSES'" >&2; exit 2; }

# PID AND ENTROPY AS WELL AS THE TIMESTAMP. Second resolution alone means two runs started in the
# same second overwrite one transcript, and the workspace lock only serialises the YugabyteDB
# runners -- stock-PostgreSQL runs can genuinely collide. The release directory already names
# itself this way, for the same reason: the file name is how a reader tells two runs apart.
OUT="kamu-money-pg/yb/out/bench-$(basename "$SQL_FILE" .sql)-yb-$(date -u +%Y%m%dT%H%M%SZ)-$$-$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n').log"
mkdir -p "$(dirname "$OUT")"

RUN_ID="kmoney-sqlyb-$$-$(od -An -N4 -tx4 /dev/urandom | tr -d ' \n')"
NAME="$RUN_ID"
cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; return 0; }
trap cleanup EXIT INT TERM HUP

YB_REF="$(./kamu-money-pg/yb/yb-image.sh "$TAG_ARG")"
NODE_IMAGE="$(./kamu-money-pg/yb/node-image.sh "$YB_REF")"

{
    echo "kmoney vs numeric(36,18) on YugabyteDB -- NOT A GATE, no pass/fail threshold"
    echo
    echo "  measured at    $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "  source sha     $(git rev-parse HEAD 2>/dev/null || echo UNKNOWN)"
    echo "  tree dirty     $([ -n "$(git status --porcelain -- . 2>/dev/null)" ] && echo yes || echo no)"
    echo "  YB base        $YB_REF"
    echo "  node image     $NODE_IMAGE  (--target node: the artifact the gate certifies)"
    echo "  fixture        $SQL_FILE"
    echo "  rows / passes  $ROWS / $PASSES"
    # A STABLE, NON-IDENTIFYING HOST FINGERPRINT. What a reader of two transcripts needs is
    # "was this the same machine?", never "which machine was it?" -- and a CPU model plus kernel
    # plus core count is a fingerprint of somebody's infrastructure, which does not belong in an
    # artefact that gets pasted into a design record. The digest answers the comparability
    # question and answers nothing else.
    echo "  host id        $(printf '%s|%s|%s' "$(uname -sm)" "$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2-)" "$(nproc 2>/dev/null)" | sha256sum | cut -c1-12)"
    echo "  host cores     $(nproc 2>/dev/null || echo unknown)"
    echo "  load average   $(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo unknown)"
    echo "  numa           $(numa_describe)"
    echo
    echo "  FEWER ROWS THAN THE PostgreSQL RUN, on purpose: DocDB writes and scans cost far more"
    echo "  than a local heap. The per-row figures normalise, and the row count is printed above"
    echo "  and inside the transcript so no figure can be divided by the wrong divisor."
    echo
} | tee "$OUT"

docker run -d --name "$NAME" --label "kamu-money-pg.bench=$RUN_ID" \
    ${NUMA_ARGS[@]+"${NUMA_ARGS[@]}"} \
    "$NODE_IMAGE" bin/yugabyted start --background=false >/dev/null

# THE PIN IS A CLAIM UNTIL THIS RUNS. docker stores `--cpuset-cpus` faithfully and the kernel
# may discard it: cgroup v2 intersects a child cpuset with its parent slice's effective set, so
# under a system.slice confined to one node the request silently resolves to the OTHER socket.
# Measured on this host. Refuse rather than measure one socket and label it the other.
numa_verify "$NAME" || exit 4

# Readiness is a query that ANSWERED, not an address that resolved.
HOST=""
READY=0
for _ in $(seq 1 120); do
    HOST="$(docker exec "$NAME" hostname -i 2>/dev/null | awk '{print $1}')" || true
    if [ -n "${HOST:-}" ] && docker exec "$NAME" bin/ysqlsh -h "$HOST" -U yugabyte \
            -c 'SELECT 1' >/dev/null 2>&1; then
        READY=1
        break
    fi
    sleep 2
done
[ "$READY" = 1 ] || { echo "bench-sql-yb: YB never answered a query (last address: ${HOST:-none})" >&2; exit 3; }
echo "bench-sql-yb: node ready at $HOST" | tee -a "$OUT"

docker cp "$SQL_FILE" "$NAME:/tmp/fixture.sql" >/dev/null

# Streams merged INSIDE the container -- `docker exec` multiplexes stdout and stderr separately,
# so a host-side `2>&1` cannot order them, and this output is read as a table.
docker exec "$NAME" bash -c \
    'exec bin/ysqlsh -h "$1" -U yugabyte -X -v ON_ERROR_STOP=1 \
        -v rows="$2" -v passes="$3" -f /tmp/fixture.sql 2>&1' \
    bench "$HOST" "$ROWS" "$PASSES" | tee -a "$OUT"

echo
echo "bench-sql-yb: transcript -> $OUT"
