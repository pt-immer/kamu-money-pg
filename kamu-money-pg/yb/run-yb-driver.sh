#!/usr/bin/env bash
# The Rust drivers against a native `kmoney` column on YugabyteDB.
#
#   kamu-money-pg/yb/run-yb-driver.sh [yb-tag] [pg-major-for-the-client-image]
#
# WHY THIS EXISTS. Three properties were each proven and never proven together:
#
#   1. Rust adapters + native `kmoney`  on stock PostgreSQL   (`just test-pg-driver`)
#   2. Rust adapters + `text` columns   on YugabyteDB         (`just test-yb`)
#   3. native `kmoney` SQL behaviour    on YugabyteDB         (regress/cluster/concurrent/...)
#
# The target this project actually claims -- a Rust service talking to native `kmoney` on
# YugabyteDB -- is the intersection, and nothing executed it. That intersection is where YSQL's
# parameter inference, prepared statements, the explicit `($1::text)::kmoney_usd` cast, wrong-tag
# error propagation, result-format selection and driver decoding all meet the FORKED backend. Passing
# the same client query against stock PostgreSQL is evidence about PostgreSQL.
#
# HOW IT CONNECTS, and why not a published port. Every other harness here talks to YugabyteDB
# through `docker exec ... ysqlsh`, and nothing in this repository publishes a container port. A
# Rust client needs a real TCP connection, so instead of breaking that rule this runs the CLIENT
# in a container too, on a private network with the node -- the same shape `cluster.sh` uses.
# `--advertise_address` is what makes the node reachable by container name; without it YugabyteDB
# advertises an address the client cannot route to and the connection times out with no error
# that names the cause.
#
# The node image has `kmoney` BAKED IN (`node-image.sh`), so there is no artifact to copy and no
# install step to get wrong: if the extension is missing the test's own `CREATE EXTENSION` fails
# loudly. The client image is the ordinary pgrx build image, used only because it already carries
# cargo and this workspace; it never loads the extension itself.
set -euo pipefail
cd "$(dirname "$0")/../.."   # repo root

# `node-image.sh` reads the built artifact triplet under kamu-money-pg/yb/out, so this is one more
# reader that must not overlap a release run rebuilding them. Re-entrant, so being invoked BY
# release-check costs nothing.
# shellcheck source=kamu-money-pg/yb/workspace-lock.sh
source "$(dirname "$0")/workspace-lock.sh"
workspace_lock "$(basename "$0")" || exit 1
# shellcheck source=scripts/docker-core-context.sh
source ./scripts/docker-core-context.sh

YB_TAG="${1:-}"
PG_MAJOR="${2:-18}"

case "$PG_MAJOR" in
    ''|*[!0-9]*) echo "run-yb-driver: pg major must be digits, got '$PG_MAJOR'" >&2; exit 2 ;;
esac

# Resolved ONCE, like every other YB runner: a mutable tag resolved twice can name two images and
# the transcript would claim one identity while exercising another.
YB_REF="${KMONEY_YB_IMAGE:-$(./kamu-money-pg/yb/yb-image.sh "$YB_TAG")}"
NODE_IMAGE="$(./kamu-money-pg/yb/node-image.sh "$YB_REF")"

RUN_ID="kmoney-ybdriver-$$-$(od -An -N4 -tx4 /dev/urandom | tr -d ' \n')"
NET="${RUN_ID}-net"
NODE="${RUN_ID}-n0"
LABEL="kamu-money-pg.ybdriver=${RUN_ID}"
IIDFILE=""

# Scoped to THIS run's label, never a broad prune: the daemon is shared. The network goes last --
# docker refuses to remove one that still has endpoints attached.
cleanup() {
    docker rm -f "$NODE" >/dev/null 2>&1 || true
    for id in $(docker ps -aq --filter "label=${LABEL}" 2>/dev/null || true); do
        docker rm -f "$id" >/dev/null 2>&1 || true
    done
    [ -n "${NET:-}" ] && docker network rm "$NET" >/dev/null 2>&1
    [ -n "${IIDFILE:-}" ] && rm -f "$IIDFILE" 2>/dev/null
    return 0
}
trap cleanup EXIT INT TERM HUP

echo "=== YugabyteDB with kmoney baked in: $NODE_IMAGE (base $YB_REF) ==="
docker network create "$NET" >/dev/null
docker run -d --name "$NODE" --network "$NET" \
    --label "${LABEL}" \
    --label "kamu-money-pg.revision=$(git rev-parse --short HEAD 2>/dev/null || echo nogit)" \
    "$NODE_IMAGE" bin/yugabyted start --background=false \
        --advertise_address="$NODE" >/dev/null

# READINESS IS A QUERY THAT ANSWERED, not an address that resolved -- the same rule
# run-yb-regress.sh learned: `hostname -i` succeeds seconds after start, so a node whose YSQL
# never came up would otherwise be called ready and fail confusingly much later.
READY=0
for _ in $(seq 1 120); do
    if docker exec "$NODE" bin/ysqlsh -h "$NODE" -U yugabyte -c 'SELECT 1' >/dev/null 2>&1; then
        READY=1
        break
    fi
    sleep 2
done
[ "$READY" = 1 ] || { echo "run-yb-driver: YB never answered a query" >&2; exit 3; }
echo "YB ready: $(docker exec "$NODE" bin/ysqlsh -h "$NODE" -U yugabyte -X -t -c 'SELECT version();' | tr -s ' ')"

echo "=== building the client image (cargo + this workspace, PG${PG_MAJOR}) ==="
# --iidfile for the reason test-matrix.sh uses it: a tag is mutable on a shared daemon, so run the
# identity this build produced rather than a name someone else can repoint. A tag of its OWN,
# never `kamu-money-pg:pg18`, which belongs to test-matrix.sh and carries a label `bench-pg` reads.
IIDFILE="$(mktemp)"
docker build "${KMONEY_CORE_DOCKER_ARGS[@]}" \
    -f kamu-money-pg/Dockerfile --build-arg "PG_MAJOR=${PG_MAJOR}" \
    --label "${LABEL}" --iidfile "${IIDFILE}" -t "kamu-money-pg-ybdriver:pg${PG_MAJOR}" . >&2
CLIENT_IMAGE="$(cat "${IIDFILE}")"
rm -f "${IIDFILE}"; IIDFILE=""

echo "=== running pg_native_column against native kmoney on YugabyteDB ==="
# 5433 is YSQL's port, NOT 5432. The host is the container name, which resolves only because the
# node advertises itself under it.
docker run --rm --network "$NET" --label "${LABEL}" \
    -e "MONEY_PG_NATIVE_URL=postgres://yugabyte@${NODE}:5433/yugabyte" \
    "$CLIENT_IMAGE" bash -euo pipefail -c '
    echo "native driver URL: ${MONEY_PG_NATIVE_URL}"

    # --test-threads=1: all four tests share one database and each runs CREATE EXTENSION IF NOT
    # EXISTS, which is not atomic -- in parallel the loser dies on a duplicate-key violation.
    #
    # Tee and assert the COUNT. Every test returns early and PASSES when MONEY_PG_NATIVE_URL is
    # unset, so "cargo test succeeded" alone would let this print OK while proving nothing. The
    # url is set above, so a skip here means something unset it, and that must be loud.
    CORE_MANIFEST="$(./scripts/resolve-core-manifest.sh)"
    cargo test --manifest-path "$CORE_MANIFEST" \
        --features postgres,sqlx --test pg_native_column \
        -- --nocapture --test-threads=1 2>&1 | tee /tmp/yb-driver.out

    if ! grep -q "4 passed" /tmp/yb-driver.out; then
        echo "run-yb-driver: FAILED -- expected 4 passing tests; the suite changed size" >&2
        exit 1
    fi
    if grep -q "skipping:" /tmp/yb-driver.out; then
        echo "run-yb-driver: FAILED -- tests SKIPPED, so nothing was proven" >&2
        exit 1
    fi
'
echo "run-yb-driver: OK -- the Rust drivers read and write a NATIVE kmoney column on YugabyteDB"
