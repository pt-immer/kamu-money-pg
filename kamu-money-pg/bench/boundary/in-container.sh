#!/usr/bin/env bash
# Compile the C control, install kmoney WITH the probe functions, start a server, run probe.sql.
# Runs INSIDE kamu-money-pg:pg<major>; driven by run-bench-boundary.sh. Never a gate.
#
# WHY A FILE RATHER THAN `docker exec bash -c '<long string>'`: the quoting is otherwise
# unreadable and shellcheck cannot see it.
set -euo pipefail
PG="${1:?major}"

BIN="$(sed -n "s/^pg${PG} = \"\\(.*\\)\\/pg_config\"/\\1/p" ~/.pgrx/config.toml)"
[ -n "$BIN" ] || { echo "boundary: no pg${PG} entry in ~/.pgrx/config.toml" >&2; exit 2; }
DATA="$HOME/.pgrx/data-${PG}"
PORT="289${PG}"

# THE C CONTROL, against THIS server's headers. A function loaded by a backend has to match that
# backend's fmgr ABI, so the include path comes from the pg_config being measured rather than
# from whatever the image happens to have installed.
echo "boundary: compiling c_noop against $("$BIN/pg_config" --version)" >&2
gcc -O2 -fPIC -shared \
    -I"$("$BIN/pg_config" --includedir-server)" \
    -o /tmp/c_noop.so /tmp/c_noop.c

# `cargo pgrx install` defaults to debug, which is invalid for a performance comparison.
#
# `boundary-probe` is what puts rs_noop and rs_noop_kmoney into the extension. probe.sql refuses
# to print a table if they are missing, so forgetting this flag fails loudly rather than
# measuring four rows and calling it a boundary.
cargo pgrx install --release --no-default-features --features "pg${PG},boundary-probe" \
    --pg-config "$BIN/pg_config" >&2

SO="$("$BIN"/pg_config --pkglibdir)/kmoney.so"
BYTES="$(stat -c %s "$SO")"
if [ "$BYTES" -gt 8000000 ]; then
    echo "boundary: $SO is $BYTES bytes -- that is a DEBUG build. Refusing to measure it." >&2
    exit 3
fi
echo "boundary: measuring a RELEASE build ($BYTES bytes)" >&2

# `unix_socket_directories=/tmp` is REQUIRED: the image runs as the unprivileged `pgrx` user and
# PostgreSQL's compiled-in socket directory is /var/run/postgresql, which that user cannot write.
# `127.0.0.1`, never `localhost`.
"$BIN/pg_ctl" -D "$DATA" -w start -l /tmp/pgrx-boundary.log \
    -o "-p $PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories=/tmp" >&2

"$BIN/dropdb"   -h 127.0.0.1 -p "$PORT" --if-exists kmoney_boundary >&2 || true
"$BIN/createdb" -h 127.0.0.1 -p "$PORT" kmoney_boundary >&2

exec "$BIN/psql" -h 127.0.0.1 -p "$PORT" -d kmoney_boundary -X -v ON_ERROR_STOP=1 \
    -v c_noop_so=/tmp/c_noop.so -f /tmp/probe.sql 2>&1
