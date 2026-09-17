#!/usr/bin/env bash
# Install `kmoney`, start pgrx's PostgreSQL, and run the cost benchmark. Runs INSIDE
# kamu-money-pg:pg<major>; driven by run-bench-pg.sh. Never a gate.
#
# WHY THIS IS A SEPARATE FILE. The image's own CMD is `cargo pgrx test`, which builds, installs,
# starts a server, runs the suite and tears it all down -- so there is no server to connect to
# from outside, and no long-lived one to benchmark against. This does the same setup and then
# stops, leaving a server up. A file rather than a `docker exec bash -c '<long string>'` because
# the quoting is otherwise unreadable and shellcheck cannot see it.
set -euo pipefail
PG="${1:?major}"

BIN="$(sed -n "s/^pg${PG} = \"\\(.*\\)\\/pg_config\"/\\1/p" ~/.pgrx/config.toml)"
[ -n "$BIN" ] || { echo "in-container: no pg${PG} entry in ~/.pgrx/config.toml" >&2; exit 2; }
DATA="$HOME/.pgrx/data-${PG}"
PORT="288${PG}"

# Performance results require an optimized extension; `cargo pgrx install` otherwise defaults
# to a debug build.
cargo pgrx install --release --no-default-features --features "pg${PG}" \
    --pg-config "$BIN/pg_config" >&2

# AND VERIFIED, because `--release` above is one word away from being deleted again by somebody
# who reads the comment about matching the test matrix and thinks it still applies. A debug .so
# carries its full debug_info: this extension is ~800 KB release and ~64 MB debug, so the two are
# two orders of magnitude apart and no threshold in between is delicate. Size rather than
# `readelf`, so the check needs no binutils in the image.
SO="$("$BIN"/pg_config --pkglibdir)/kmoney.so"
BYTES="$(stat -c %s "$SO")"
if [ "$BYTES" -gt 8000000 ]; then
    echo "in-container: $SO is $BYTES bytes -- that is a DEBUG build." >&2
    echo "in-container: an unoptimised extension measures the absence of optimisation, and the" >&2
    echo "in-container: numbers are not slow versions of the real ones. They are about different" >&2
    echo "in-container: code. Refusing to benchmark it." >&2
    exit 3
fi
echo "in-container: measuring a RELEASE build ($BYTES bytes)" >&2

# `unix_socket_directories=/tmp` is REQUIRED, not tidiness: the image runs as the unprivileged
# `pgrx` user and PostgreSQL's compiled-in socket directory is /var/run/postgresql, which that
# user cannot write. Without it the postmaster starts, binds the port, and then dies with
# `could not create lock file ... Permission denied` -- a failure whose message is about a lock
# file and whose cause is the socket path.
#
# `127.0.0.1`, never `localhost`: the house rule, and here it also avoids an IPv6 first-resolution
# reaching a listener that is only bound to IPv4.
"$BIN/pg_ctl" -D "$DATA" -w start -l /tmp/pgrx-bench.log \
    -o "-p $PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories=/tmp" >&2

# The benchmark owns its own database, so nothing it drops can belong to something else.
"$BIN/dropdb"   -h 127.0.0.1 -p "$PORT" --if-exists kmoney_bench >&2 || true
"$BIN/createdb" -h 127.0.0.1 -p "$PORT" kmoney_bench >&2

exec "$BIN/psql" -h 127.0.0.1 -p "$PORT" -d kmoney_bench -X -v ON_ERROR_STOP=1 \
    -f /tmp/sql-cost.sql 2>&1
