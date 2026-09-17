#!/usr/bin/env bash
# Run the ported case suite (kamu-money-pg/tests/pg_regress) against a live single-node YugabyteDB.
#
#   kamu-money-pg/yb/run-yb-regress.sh [yb-image] [artifact-dir]
#
# `cargo pgrx test` owns its PostgreSQL server and cannot target YugabyteDB. This portable wire
# suite runs the same cases and hand-authored goldens against YugabyteDB and stock PostgreSQL 15.
#
# Prereq: kamu-money-pg/yb/out/{kmoney.so,kmoney.control,kmoney--*.sql} built by `just yb-build`.
set -euo pipefail
cd "$(dirname "$0")/../.."   # repo root

# This script writes under ${KMONEY_RUN_ROOT:-kamu-money-pg/yb/out}. With KMONEY_RUN_ROOT unset --
# the default -- that is one tree shared with every other suite, so this is one writer among
# several that must not overlap: a release check reads the very files a hand-started run of this
# script would overwrite. Setting KMONEY_RUN_ROOT gives a run its own tree and the contention
# stops existing rather than being serialised. The lock is re-entrant, so being invoked BY
# release-check is free.
# shellcheck source=kamu-money-pg/yb/workspace-lock.sh
source "$(dirname "$0")/workspace-lock.sh"
workspace_lock "$(basename "$0")" || exit 1

YB_IMAGE="${1:-$(./kamu-money-pg/yb/yb-image.sh)}"
ART="${2:-${KMONEY_RUN_ROOT:-kamu-money-pg/yb/out}}"

# Baked or copied, verified by hash either way -- see install.sh, which sources artifact.sh for the
# coherent-triplet-by-exact-name rule.
# shellcheck source=kamu-money-pg/yb/install.sh
source ./kamu-money-pg/yb/install.sh

RUN_ID="kmoney-regress-$$-$(od -An -N4 -tx4 /dev/urandom | tr -d ' \n')"
NAME="$RUN_ID"
# EXIT alone is not enough: a kill during the readiness wait would orphan the container, which the
# shared dockerd cannot afford.
cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; return 0; }
trap cleanup EXIT INT TERM HUP

echo "starting YugabyteDB ($YB_IMAGE) as $NAME ..."
docker run -d --name "$NAME" --label "kamu-money-pg.ybtest=$RUN_ID" \
  --label "kamu-money-pg.revision=$(git rev-parse --short HEAD 2>/dev/null || echo nogit)" \
  "$YB_IMAGE" bin/yugabyted start --background=false >/dev/null

# Readiness requires a successful query; resolving the advertised address alone is insufficient.
HOST=""
READY=0
for _ in $(seq 1 120); do
  HOST="$(docker exec "$NAME" hostname -i 2>/dev/null | awk '{print $1}')" || true
  if [ -n "${HOST:-}" ] && docker exec "$NAME" bin/ysqlsh -h "$HOST" -U yugabyte -c 'SELECT 1' \
      >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 2
done
[ "$READY" = 1 ] || { echo "YB never answered a query (last address: ${HOST:-none})" >&2; exit 3; }
echo "YB ready at $HOST: $(docker exec "$NAME" bin/ysqlsh -h "$HOST" -U yugabyte -X -t -c 'SELECT version();' | tr -s ' ')"

yb_ensure_extension "$NAME" "$ART"
echo "kmoney present ($YB_INSTALL_MODE, sha256 $YB_INSTALL_SHA); running the case suite ..."

# The generated wrapper merges ysqlsh streams inside the container and avoids quoting loss when
# run-suite.sh appends client flags.
#
# --server-exec is how 09-wire's crafted BINARY COPY payloads get onto the SERVER's filesystem:
# the recv functions take `internal`, so COPY (FORMAT BINARY) from a file is the only in-database
# route to them, and SQL cannot write arbitrary bytes to a file.
mkdir -p "$ART"
CLIENT_WRAPPER="$ART/client-$RUN_ID.sh"
cat > "$CLIENT_WRAPPER" <<EOF
#!/usr/bin/env bash
exec docker exec -i $NAME bash -c 'exec bin/ysqlsh -h $HOST -U yugabyte "\$@" 2>&1' ysqlsh "\$@"
EOF
chmod +x "$CLIENT_WRAPPER"
# The wrapper names this run, so it goes when the run does.
trap 'cleanup; rm -f "$CLIENT_WRAPPER"' EXIT INT TERM HUP

# Do not `exec`: this shell owns the cleanup trap. `set -e` propagates the suite's status while
# preserving cleanup on the shared daemon.
./kamu-money-pg/tests/pg_regress/run-suite.sh \
    --client "$CLIENT_WRAPPER" \
    --server-exec "docker exec -i $NAME bash" \
    --label yb-native \
    --outdir "$ART"/regress-yb
