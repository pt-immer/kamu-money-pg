#!/usr/bin/env bash
# What a pgrx call costs, measured against a null C function of the same signature. NEVER a gate.
#
#   kamu-money-pg/bench/run-bench-boundary.sh [major]      # default 18
#
# Probe functions live behind `--features boundary-probe`; they are reproducible but absent from
# the shipped SQL surface.
#
# NO THRESHOLD, the same rule as every other fixture here: it reports, and it refuses an
# unusable measurement. Those are different things, and the difference is written down in
# boundary/probe.sql.
set -euo pipefail
cd "$(dirname "$0")/../.."   # repo root

# Lock before touching the shared default run root. A distinct `KMONEY_RUN_ROOT` isolates a run;
# descendants of the release gate inherit the descriptor and re-enter.
# shellcheck source=kamu-money-pg/yb/workspace-lock.sh
source ./kamu-money-pg/yb/workspace-lock.sh
workspace_lock "$(basename "$0")" || exit 1

# shellcheck source=kamu-money-pg/bench/numa.sh
source "$(dirname "$0")/numa.sh"
# Empty when unpinned; the `+` form keeps `set -u` happy with an empty array.
read -r -a NUMA_ARGS <<< "$(numa_docker_args)"

PG="${1:-18}"
# PID AND ENTROPY AS WELL AS THE TIMESTAMP. Second resolution alone means two runs started in the
# same second overwrite one transcript, and the workspace lock only serialises the YugabyteDB
# runners -- stock-PostgreSQL runs can genuinely collide. The release directory already names
# itself this way, for the same reason: the file name is how a reader tells two runs apart.
OUT="kamu-money-pg/yb/out/bench-boundary-pg${PG}-$(date -u +%Y%m%dT%H%M%SZ)-$$-$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n').log"
mkdir -p "$(dirname "$OUT")"

RUN_ID="kmoney-boundary-$$-$(od -An -N4 -tx4 /dev/urandom | tr -d ' \n')"
NAME="$RUN_ID"
# The daemon is shared across several organisations' runners: this container belongs to this
# script, by label, and the trap covers the signals as well as EXIT.
cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; return 0; }
trap cleanup EXIT INT TERM HUP

# Resolved to an image ID once, and the ID is what runs -- the tag is mutable and this daemon is
# shared. Same rule as run-bench-pg.sh and test-matrix.sh.
TAG="kamu-money-pg:pg${PG}"
if ! IMAGE="$(docker image inspect --format '{{ .Id }}' "$TAG" 2>/dev/null)"; then
    echo "boundary: $TAG is not built. Run 'just test-pg $PG' first." >&2
    exit 2
fi
REVISION="$(git rev-parse HEAD 2>/dev/null || echo UNKNOWN)"
REVISION_SHORT="$(git rev-parse --short HEAD 2>/dev/null || echo nogit)"
IMAGE_REVISION="$(docker image inspect --format '{{ index .Config.Labels "kamu-money-pg.revision" }}' "$IMAGE" 2>/dev/null || true)"
if [ "$IMAGE_REVISION" != "$REVISION_SHORT" ]; then
    echo "boundary: REFUSING -- $TAG was built from ${IMAGE_REVISION:-<unlabelled>}, checkout is at $REVISION_SHORT." >&2
    echo "boundary: rebuild with 'just test-pg $PG', or set BENCH_ALLOW_STALE_IMAGE=1." >&2
    [ "${BENCH_ALLOW_STALE_IMAGE:-0}" = "1" ] || exit 2
    echo "boundary: proceeding anyway (BENCH_ALLOW_STALE_IMAGE=1)" >&2
fi

{
    echo "pgrx boundary probe -- NOT A GATE, no pass/fail threshold"
    echo
    echo "  measured at    $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "  source sha     $REVISION"
    echo "  tree dirty     $([ -n "$(git status --porcelain -- . 2>/dev/null)" ] && echo yes || echo no)"
    echo "  image tag      $TAG (mutable; the ID below is what ran)"
    echo "  image id       $IMAGE"
    echo "  image built at ${IMAGE_REVISION:-<unlabelled>}"
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

docker run -d --name "$NAME" --label "kamu-money-pg.bench=$RUN_ID" \
    ${NUMA_ARGS[@]+"${NUMA_ARGS[@]}"} \
    --entrypoint /bin/sh "$IMAGE" -c 'sleep infinity' >/dev/null

# THE PIN IS A CLAIM UNTIL THIS RUNS. docker stores `--cpuset-cpus` faithfully and the kernel
# may discard it: cgroup v2 intersects a child cpuset with its parent slice's effective set, so
# under a system.slice confined to one node the request silently resolves to the OTHER socket.
# Measured on this host. Refuse rather than measure one socket and label it the other.
numa_verify "$NAME" || exit 4

docker cp kamu-money-pg/bench/boundary/c_noop.c        "$NAME:/tmp/c_noop.c"
docker cp kamu-money-pg/bench/boundary/probe.sql       "$NAME:/tmp/probe.sql"
docker cp kamu-money-pg/bench/boundary/in-container.sh "$NAME:/tmp/in-container.sh"

# Streams merged INSIDE the container: `docker exec` multiplexes stdout and stderr separately, so
# a host-side `2>&1` cannot order them -- and this output is read as a table.
docker exec "$NAME" bash -c 'exec bash /tmp/in-container.sh "$1" 2>&1' boundary "$PG" \
    | tee -a "$OUT"

echo
echo "boundary: transcript -> $OUT"
