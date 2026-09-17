#!/usr/bin/env bash
# What a pgrx call costs ON YUGABYTEDB, against a null C function of the same signature.
# NEVER a gate.
#
#   kamu-money-pg/bench/run-bench-boundary-yb.sh [tag]
#
# YugabyteDB is measured separately from PostgreSQL. YSQL is multi-threaded, so pgrx touches the
# thread-local `YbCurrentMemoryContext` on every call; stock PostgreSQL cannot measure that cost.
#
# WHY A DEDICATED IMAGE. Both functions have to be compiled against the SAME server headers and
# load into the SAME backend, or the subtraction is between two different ABIs. So the extension
# is built with `--build-arg EXTRA_FEATURES=boundary-probe` and `c_noop.so` is compiled in the
# same `build` stage, both against YB's own PG15 headers and glibc. That image is
# `--target boundary-node`, deliberately NOT the `node` target the release gate certifies: a
# deployable image must never carry a function whose only purpose is to be timed.
#
# NO TABLE. `generate_series` runs in the YSQL backend, so DocDB is out of the path while the
# thread-local memory context is unchanged -- which is what makes a few nanoseconds resolvable at
# all. Over a real table YB's scan floor is ~378 ms against stock PostgreSQL's ~23 ms, and it is
# the floor's VARIANCE, not its magnitude, that swamps the signal. A large floor cancels on
# subtraction; an unstable one does not.
set -euo pipefail
cd "$(dirname "$0")/../.."   # repo root

# shellcheck source=kamu-money-pg/bench/numa.sh
source "$(dirname "$0")/numa.sh"
# Empty when unpinned; the `+` form keeps `set -u` happy with an empty array.
read -r -a NUMA_ARGS <<< "$(numa_docker_args)"

# This writes under kamu-money-pg/yb/out/ and builds an image from the same context the release
# gate uses, so it is one writer among several that must not overlap.
# shellcheck source=kamu-money-pg/yb/workspace-lock.sh
source "$(dirname "$0")/../yb/workspace-lock.sh"
workspace_lock "$(basename "$0")" || exit 1
# shellcheck source=scripts/docker-core-context.sh
source ./scripts/docker-core-context.sh

TAG_ARG="${1:-}"
# PID AND ENTROPY AS WELL AS THE TIMESTAMP. Second resolution alone means two runs started in the
# same second overwrite one transcript, and the workspace lock only serialises the YugabyteDB
# runners -- stock-PostgreSQL runs can genuinely collide. The release directory already names
# itself this way, for the same reason: the file name is how a reader tells two runs apart.
OUT="kamu-money-pg/yb/out/bench-boundary-yb-$(date -u +%Y%m%dT%H%M%SZ)-$$-$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n').log"
mkdir -p "$(dirname "$OUT")"

RUN_ID="kmoney-bound-yb-$$-$(od -An -N4 -tx4 /dev/urandom | tr -d ' \n')"
NAME="$RUN_ID"
# The daemon is shared across several organisations' runners: this container belongs to this
# script, by label, and the trap covers the signals as well as EXIT.
cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; return 0; }
trap cleanup EXIT INT TERM HUP

# ONE identity, resolved once, pin-checked -- the same discipline every other YB path uses.
YB_REF="$(./kamu-money-pg/yb/yb-image.sh "$TAG_ARG")"
REVISION="$(git rev-parse HEAD 2>/dev/null || echo UNKNOWN)"

{
    echo "pgrx boundary probe on YugabyteDB -- NOT A GATE, no pass/fail threshold"
    echo
    echo "  measured at    $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "  source sha     $REVISION"
    echo "  tree dirty     $([ -n "$(git status --porcelain -- . 2>/dev/null)" ] && echo yes || echo no)"
    echo "  YB base        $YB_REF"
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
    echo "  THIS PROBE RESOLVES SINGLE-DIGIT NANOSECONDS. If the load average above is not near"
    echo "  zero, the floor-stability check inside will refuse the run rather than print a table."
    echo
} | tee "$OUT"

# BUILT BY ID, RUN BY ID. `--iidfile` records the image this build actually produced; a tag on a
# shared daemon can be moved between the build and the run. Same rule as test-matrix.sh.
IIDFILE="$(mktemp)"
trap 'rm -f "$IIDFILE"; cleanup' EXIT INT TERM HUP
echo "boundary-yb: building the probe image (this compiles the extension from source) ..." | tee -a "$OUT"
docker build "${KMONEY_CORE_DOCKER_ARGS[@]}" \
    -f kamu-money-pg/yb/Dockerfile --target boundary-node \
    --build-arg YB_IMAGE="$YB_REF" \
    --build-arg EXTRA_FEATURES=boundary-probe \
    --label "kamu-money-pg.revision=$(git rev-parse --short HEAD 2>/dev/null || echo nogit)" \
    --iidfile "$IIDFILE" . >&2
IMAGE="$(cat "$IIDFILE")"
echo "boundary-yb: probe image $IMAGE" | tee -a "$OUT"

docker run -d --name "$NAME" --label "kamu-money-pg.bench=$RUN_ID" \
    ${NUMA_ARGS[@]+"${NUMA_ARGS[@]}"} \
    "$IMAGE" bin/yugabyted start --background=false >/dev/null

# THE PIN IS A CLAIM UNTIL THIS RUNS. docker stores `--cpuset-cpus` faithfully and the kernel
# may discard it: cgroup v2 intersects a child cpuset with its parent slice's effective set, so
# under a system.slice confined to one node the request silently resolves to the OTHER socket.
# Measured on this host. Refuse rather than measure one socket and label it the other.
numa_verify "$NAME" || exit 4

# Readiness requires a successful query; resolving the container address is insufficient.
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
[ "$READY" = 1 ] || { echo "boundary-yb: YB never answered a query (last address: ${HOST:-none})" >&2; exit 3; }
echo "boundary-yb: node ready at $HOST" | tee -a "$OUT"

# Streams merged INSIDE the container: `docker exec` multiplexes stdout and stderr separately, so
# a host-side `2>&1` cannot order them -- and this output is read as a table.
docker exec "$NAME" bash -c \
    'exec bin/ysqlsh -h "$1" -U yugabyte -X -v ON_ERROR_STOP=1 \
        -v c_noop_so=/home/yugabyte/postgres/lib/c_noop.so \
        -f /home/yugabyte/probe.sql 2>&1' \
    boundary "$HOST" | tee -a "$OUT"

echo
echo "boundary-yb: transcript -> $OUT"
