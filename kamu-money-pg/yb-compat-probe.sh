#!/usr/bin/env bash
# Reproduce the blockers for an unadapted `kamu-money-pg` build on the baseline YugabyteDB image.
#
#   just yb-probe            (or: ./kamu-money-pg/yb-compat-probe.sh [yb-image] [builder-image])
#
# Two independent blockers are asserted:
#
#   0  both blockers reproduced
#   1  a blocker is gone; reassess the unadapted-build assumptions
#   2  the probe could not run (missing builder image)
#
# The probe compiles extracted YugabyteDB headers and asks YugabyteDB to load a shared object
# built against modern glibc. Its baseline image has no compiler, so compilation uses a builder
# image.
set -euo pipefail

# Resolve the baseline tag to a digest before testing it.
YB_IMAGE="${1:-$(./kamu-money-pg/yb/yb-image.sh yugabytedb/yugabyte:2025.2.4.1-b4)}"
# Reused because it already carries build-essential and a modern glibc. Any Debian-with-gcc
# image works; this one avoids a pull on a machine that has run the matrix.
BUILDER_IMAGE="${2:-kamu-money-pg:pg18}"

RUN_ID="yb-probe-$$-$(od -An -N4 -tx4 /dev/urandom | tr -d ' \n')"
NAME="${RUN_ID}"
WORK="$(mktemp -d)"

# --- assertion machinery -----------------------------------------------------------------
#
# The assertion direction is intentionally negative: each operation must fail with its expected
# signature. A successful operation means this baseline assumption changed.
BLOCKERS_CONFIRMED=0
BLOCKERS_LOST=""

# assert_blocker <label> <status> <output> <signature>
#   Requires a non-zero status AND the expected error text. Either alone is too weak: a
#   container that dies for an unrelated reason gives a non-zero status, and a signature can
#   appear in a warning on an otherwise successful build.
assert_blocker() {
  label="$1"; status="$2"; output="$3"; signature="$4"
  if [ "$status" -ne 0 ] && printf '%s' "$output" | grep -q -- "$signature"; then
    echo "CONFIRMED: ${label}"
    echo "           (exit ${status}, matched '${signature}')"
    BLOCKERS_CONFIRMED=$((BLOCKERS_CONFIRMED + 1))
    return 0
  fi
  echo "NOT REPRODUCED: ${label}"
  echo "           expected a non-zero exit AND '${signature}'; got exit ${status}"
  BLOCKERS_LOST="${BLOCKERS_LOST}
  - ${label}"
  return 0
}

# EXIT alone is not enough: it does not fire if the shell is killed while blocked in the
# readiness loop below, which is where this script spends nearly all of its time. A container
# that outlives its script is exactly the dangling this repo has already paid for once.
cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  rm -rf "$WORK" 2>/dev/null || true
  return 0
}
trap cleanup EXIT INT TERM HUP

if ! docker image inspect "$BUILDER_IMAGE" >/dev/null 2>&1; then
  echo "builder image '$BUILDER_IMAGE' is not present."
  echo "Run 'just test-pg 18' first, or pass a Debian-with-gcc image as the second argument."
  exit 2
fi

echo "=== 1. What PostgreSQL is YugabyteDB, actually? ==============================="
docker run -d --name "$NAME" --label "kamu-money-pg.probe=${RUN_ID}" \
  "$YB_IMAGE" bin/yugabyted start --background=false >/dev/null
# yugabyted binds YSQL to the node's advertised address, never to loopback, so the host has to
# be discovered. Connecting to 127.0.0.1 fails with ECONNREFUSED and looks like a slow start.
HOST=""
for _ in $(seq 1 120); do
  HOST="$(docker exec "$NAME" hostname -i 2>/dev/null | awk '{print $1}')" || true
  [ -n "${HOST:-}" ] && docker exec "$NAME" bin/ysqlsh -h "$HOST" -U yugabyte -c 'SELECT 1' \
      >/dev/null 2>&1 && break
  sleep 2
done
docker exec "$NAME" bin/ysqlsh -h "$HOST" -U yugabyte -X -t -c 'SELECT version();'

echo
echo "=== 2. BLOCKER ONE: the shipped headers really do not compile ================="
echo "YugabyteDB ships pg_config, server headers and the extension directories, so building"
echo "against it looks possible. Below, a real compiler is pointed at those real headers."
echo
echo "--- the include that starts it ---"
docker exec "$NAME" sh -c \
  'grep -n "ybc_util" /home/yugabyte/postgres/include/server/utils/elog.h | head -3'
echo "--- is that header anywhere in the image? ---"
FOUND="$(docker exec "$NAME" sh -c 'find / -name ybc_util.h 2>/dev/null | head -3')"
echo "${FOUND:-NOT FOUND ANYWHERE IN THE IMAGE - there is nothing to include}"

echo "--- and the image ships no compiler to try it with ---"
docker exec "$NAME" sh -c 'for c in cc gcc clang; do command -v $c || echo "$c: absent"; done'

echo
echo "--- extracting YugabyteDB's server headers and compiling against them for real ---"
docker cp "$NAME:/home/yugabyte/postgres/include/server" "$WORK/server" >/dev/null
printf '#include "postgres.h"\nint probe(void) { return 0; }\n' > "$WORK/probe.c"

# `cc` is the container's last command, so its status becomes `docker run`'s status. Avoid a
# pipeline, merge stderr into the capture, and read `$?` immediately.
set +e
CC_OUTPUT="$(docker run --rm --label "kamu-money-pg.probe=${RUN_ID}" \
  -v "$WORK:/probe:ro" --entrypoint sh "$BUILDER_IMAGE" -c \
  'cc -c -I/probe/server -o /tmp/probe.o /probe/probe.c 2>&1')"
CC_STATUS=$?
set -e

printf '%s\n' "$CC_OUTPUT" | head -20
echo
assert_blocker "blocker one: YugabyteDB's own server headers do not compile" \
  "$CC_STATUS" "$CC_OUTPUT" "ybc_util.h"

echo
echo "=== 3. BLOCKER TWO: a foreign-built .so really will not load ==================="
docker exec "$NAME" sh -c 'ldd --version 2>/dev/null | head -1'
echo "--- building a .so against the builder's modern glibc ---"
# `gettid()` was added to glibc in 2.30. Referencing it is the smallest honest way to produce
# a library that REQUIRES a newer glibc than this image has, which is exactly the condition a
# real kmoney.so hits. The point is the loader's verdict, not this function's body.
cat > "$WORK/needs_new_glibc.c" <<'EOF'
#define _GNU_SOURCE
#include <unistd.h>
long probe_tid(void) { return (long) gettid(); }
EOF
docker run --rm --label "kamu-money-pg.probe=${RUN_ID}" \
  -v "$WORK:/probe" --entrypoint sh "$BUILDER_IMAGE" -c \
  'cc -shared -fPIC -o /probe/needs_new_glibc.so /probe/needs_new_glibc.c && \
   objdump -T /probe/needs_new_glibc.so | grep -o "GLIBC_2\.[0-9]*" | sort -u | tail -3'

echo "--- copying it into the running YugabyteDB container and making PG dlopen it ---"
docker cp "$WORK/needs_new_glibc.so" "$NAME:/tmp/needs_new_glibc.so" >/dev/null
# Use `CREATE FUNCTION`, not unsupported `LOAD`, to reach the dynamic loader.
# `CREATE FUNCTION ... LANGUAGE C` is the path an extension actually takes, and it dlopens the
# library at creation -- before any symbol lookup or magic-block check, so a glibc mismatch
# surfaces first, which is precisely the ordering this blocker depends on.
#
# `-v ON_ERROR_STOP=1` is what makes the status meaningful: without it psql reports success
# after a failed statement, and the assertion below would rest on the message alone.
# Merge streams inside the container because the host cannot order multiplexed docker streams.
# The SQL goes in as a positional argument so its embedded single quotes never meet the container
# shell's quoting.
set +e
LOAD_OUTPUT="$(docker exec "$NAME" bash -c \
  'exec bin/ysqlsh -h "$1" -U yugabyte -X -v ON_ERROR_STOP=1 -c "$2" 2>&1' \
  ysqlsh "$HOST" \
  "CREATE FUNCTION probe_tid() RETURNS bigint AS '/tmp/needs_new_glibc.so', 'probe_tid' LANGUAGE C;")"
LOAD_STATUS=$?
set -e

printf '%s\n' "$LOAD_OUTPUT" | head -6
echo
# The signature is the loader's verdict, not the exact glibc version: which symbol version is
# missing depends on the builder image, and pinning "GLIBC_2.30" would turn a newer builder into
# a false "not reproduced". What must hold is that the dynamic loader refused a symbol version.
assert_blocker "blocker two: a foreign-built .so is refused by YugabyteDB's loader" \
  "$LOAD_STATUS" "$LOAD_OUTPUT" "GLIBC_"

echo
echo "--- for the record, what YugabyteDB says to LOAD itself (diagnostic, not asserted) ---"
# This diagnostic is not a blocker assertion; `LOAD not supported yet` is distinct from a glibc
# loader refusal.
# `head -3` makes the ordering matter even for a diagnostic: with the streams merged on the host,
# the three lines kept could be the three that arrived first rather than the three that were
# printed first, and the interesting one is not guaranteed to be among them.
set +e
docker exec "$NAME" bash -c \
  'exec bin/ysqlsh -h "$1" -U yugabyte -X -c "$2" 2>&1' \
  ysqlsh "$HOST" "LOAD '/tmp/needs_new_glibc.so';" | head -3
set -e

echo
echo "=== CONCLUSION ================================================================"
echo "Scope of what was just tested: the image named above, built the conventional way."
echo

if [ -n "$BLOCKERS_LOST" ]; then
  echo "PROBE FAILED: ${BLOCKERS_CONFIRMED} of 2 blockers reproduced."
  echo "These no longer reproduce:${BLOCKERS_LOST}"
  echo
  echo "The baseline changed. Reassess the unadapted build path using the transcript above."
  exit 1
fi

echo "Both blockers CONFIRMED: reproduced and asserted, not merely executed."
echo "This does not test the adapted native build; use 'just yb-native' and 'just yb-ab' for it."
