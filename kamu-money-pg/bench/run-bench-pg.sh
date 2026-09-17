#!/usr/bin/env bash
# Run kamu-money-pg/bench/sql-cost.sql on a stock PostgreSQL with `kmoney` installed. NEVER a gate.
#
#   kamu-money-pg/bench/run-bench-pg.sh [major]      # default 18
#
# NO THRESHOLD, ON PURPOSE -- the same rule `just bench-yb` states: a limit invented before there
# is a baseline to regress against either never fires or fires on somebody else's hardware. If
# these are ever to gate, a baseline on known hardware comes first, and that is a decision.
#
# THE OUTPUT IS THE ARTEFACT. Environment identity is printed WITH the numbers, because a timing
# without the machine it came from is not reproducible even in principle, and the host is the one
# piece of context that cannot be recovered from the repository later.
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
OUT="kamu-money-pg/yb/out/bench-pg${PG}-$(date -u +%Y%m%dT%H%M%SZ)-$$-$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n').log"
mkdir -p "$(dirname "$OUT")"

RUN_ID="kmoney-bench-$$-$(od -An -N4 -tx4 /dev/urandom | tr -d ' \n')"
NAME="$RUN_ID"
# The daemon is shared across several organisations' runners: this container belongs to this
# script, by label, and the trap covers the signals as well as EXIT.
cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; return 0; }
trap cleanup EXIT INT TERM HUP

# Built by the ordinary test matrix, so the extension under measurement is the one the tests ran.
#
# Resolve the mutable tag once and run the resulting image ID. The revision-label check below
# also ties the measurement to the named source revision.
TAG="kamu-money-pg:pg${PG}"
if ! IMAGE="$(docker image inspect --format '{{ .Id }}' "$TAG" 2>/dev/null)"; then
    echo "bench-pg: $TAG is not built. Run 'just test-pg $PG' first -- this measures the same" >&2
    echo "bench-pg: image the test matrix builds, so the numbers describe tested code." >&2
    exit 2
fi

# Require the tested image to match this source revision.
REVISION="$(git rev-parse HEAD 2>/dev/null || echo UNKNOWN)"
# The test matrix stamps the short revision.
REVISION_SHORT="$(git rev-parse --short HEAD 2>/dev/null || echo nogit)"
IMAGE_REVISION="$(docker image inspect --format '{{ index .Config.Labels "kamu-money-pg.revision" }}' "$IMAGE" 2>/dev/null || true)"
if [ "$IMAGE_REVISION" != "$REVISION_SHORT" ]; then
    echo "bench-pg: REFUSING -- $TAG was built from a different revision." >&2
    echo "bench-pg:   image built from  ${IMAGE_REVISION:-<unlabelled>}" >&2
    echo "bench-pg:   checkout is at    $REVISION_SHORT" >&2
    echo "bench-pg: the log would name this revision beside timings from that one. Rebuild with:" >&2
    echo "bench-pg:   just test-pg $PG" >&2
    echo "bench-pg: (set BENCH_ALLOW_STALE_IMAGE=1 to measure the old image deliberately; the" >&2
    echo "bench-pg:  log then records which revision was actually measured.)" >&2
    [ "${BENCH_ALLOW_STALE_IMAGE:-0}" = "1" ] || exit 2
    echo "bench-pg: proceeding anyway (BENCH_ALLOW_STALE_IMAGE=1)" >&2
fi

{
    echo "kmoney SQL cost benchmark -- informational; no pass/fail threshold"
    echo
    echo "  measured at    $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "  source sha     $REVISION"
    echo "  tree dirty     $([ -n "$(git status --porcelain -- . 2>/dev/null)" ] && echo yes || echo no)"
    echo "  image tag      $TAG (a mutable convenience name; the ID below is what ran)"
    echo "  image id       $IMAGE"
    # Printed even though it is checked above, because the check has a deliberate override and a
    # reader of the log should not have to know whether it was used.
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
    echo "  A LOADED HOST INFLATES EVERY ROW. If the load average above is not near zero, treat"
    echo "  these as an ordering rather than as magnitudes, and re-run on a quiet machine before"
    echo "  quoting any single figure."
    echo
} | tee "$OUT"

# The image's CMD is `cargo pgrx test`, which builds, runs the suite and tears its server down --
# so it is started idle here and driven by exec instead. `in-container.sh` does the same install
# the test matrix performs and then leaves a server up.
docker run -d --name "$NAME" --label "kamu-money-pg.bench=$RUN_ID" \
    ${NUMA_ARGS[@]+"${NUMA_ARGS[@]}"} \
    --entrypoint /bin/sh "$IMAGE" -c 'sleep infinity' >/dev/null

# THE PIN IS A CLAIM UNTIL THIS RUNS. docker stores `--cpuset-cpus` faithfully and the kernel
# may discard it: cgroup v2 intersects a child cpuset with its parent slice's effective set, so
# under a system.slice confined to one node the request silently resolves to the OTHER socket.
# Measured on this host. Refuse rather than measure one socket and label it the other.
numa_verify "$NAME" || exit 4

docker cp kamu-money-pg/bench/sql-cost.sql    "$NAME:/tmp/sql-cost.sql"
docker cp kamu-money-pg/bench/in-container.sh "$NAME:/tmp/in-container.sh"

echo "bench-pg: installing the extension (same build the test matrix runs) ..." | tee -a "$OUT"
# Streams merged INSIDE the container: `docker exec` multiplexes stdout and stderr separately, so
# a host-side `2>&1` cannot order them -- and this output is read as a table.
docker exec "$NAME" bash -c 'exec bash /tmp/in-container.sh "$1" 2>&1' bench "$PG" \
    | tee -a "$OUT"

echo | tee -a "$OUT"
echo "bench-pg: full output retained at $OUT" | tee -a "$OUT"
