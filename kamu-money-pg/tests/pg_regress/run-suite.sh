#!/usr/bin/env bash
# Run the `kmoney` case suite against ANY live PostgreSQL-protocol server, and diff each case
# against its committed golden output.
#
#   run-suite.sh --client "<client invocation>" --label <name> [--outdir DIR]
#                [--server-exec "<prefix that reads a script on stdin>"] [case ...]
#
# WHY THIS EXISTS. `cargo pgrx test` manages its own PostgreSQL and cannot be aimed at
# YugabyteDB, so the in-backend `#[pg_test]` contract had never run there. Everything YugabyteDB
# was known to do came from one
# ~112-line script (yb/abi_battery.sql). This suite is that contract restated as SQL, so it
# runs against a single YB node, any node of a YB cluster, or the stock-PG15 reference,
# unchanged.
#
# WHY NOT THE `pg_regress` BINARY. It needs a --bindir and a schedule file, and the YugabyteDB
# image is not guaranteed to ship one. The shape is what matters, not the tool: sql/ +
# expected/, one output per case, an exact diff.
#
# THE SQL IS FED ON STDIN, never as a path. That is what lets one runner drive
# `docker exec -i <node> bin/ysqlsh ...` and a local `psql` with no transport code and without
# copying the suite into a container. The error-location prefix psql prints for a stdin script
# (`psql:<stdin>:12:`) is harness metadata and is normalized away below; the message text after
# it is kmoney's and is compared byte for byte.
#
# THE CLIENT MUST MERGE ITS OWN stderr INTO stdout, ON ITS OWN SIDE OF ANY TRANSPORT.
# This is a REQUIREMENT ON CALLERS, and it is not pedantry -- it was measured. `docker exec`
# carries stdout and stderr as two independently multiplexed streams, so a `2>&1` out here, on the
# host, cannot order them: expected-error output arrived one `\echo` section LATE, and only
# sometimes, which made 2 of 11 cases flaky rather than broken. Every caller therefore passes a
# client that redirects INSIDE the container (`bash -c 'exec ysqlsh "$@" 2>&1'`), so exactly one
# stream ever crosses the boundary. The `2>&1` below stays as a backstop for a local client.
#
# GOLDEN FILES ARE HAND-AUTHORED FROM THE LITERALS THE RUST TESTS ALREADY ASSERT, and there is
# deliberately NO REGENERATE MODE. A suite that can bless its own output certifies whatever it
# currently does -- the same reason yb/assert-battery.sh asserts values rather than shapes. To
# change a golden, change the assertion in lib.rs first, then copy the value across.
set -euo pipefail

SUITE="$(cd "$(dirname "$0")" && pwd)"

CLIENT=""
LABEL=""
OUTDIR=""
SERVER_EXEC=""
CASES=()

while [ $# -gt 0 ]; do
    case "$1" in
        --client)      CLIENT="$2"; shift 2 ;;
        --label)       LABEL="$2"; shift 2 ;;
        --outdir)      OUTDIR="$2"; shift 2 ;;
        --server-exec) SERVER_EXEC="$2"; shift 2 ;;
        --*)           echo "run-suite: unknown option $1" >&2; exit 2 ;;
        *)             CASES+=("$1"); shift ;;
    esac
done

[ -n "$CLIENT" ] || { echo "run-suite: --client is required" >&2; exit 2; }
[ -n "$LABEL" ]  || { echo "run-suite: --label is required" >&2; exit 2; }
OUTDIR="${OUTDIR:-$SUITE/results/$LABEL}"

# Cases are DISCOVERED from the filesystem, never listed here. A list is a second place to
# remember, and the list is the half that gets forgotten -- a new case would sit in sql/ never
# running while the suite reported green.
if [ ${#CASES[@]} -eq 0 ]; then
    for f in "$SUITE"/sql/*.sql; do
        CASES+=("$(basename "$f" .sql)")
    done
fi
[ ${#CASES[@]} -gt 0 ] || { echo "run-suite: no cases found under $SUITE/sql" >&2; exit 2; }

mkdir -p "$OUTDIR"

# Normalize only harness-specific output; refusal messages remain byte-exact.
#
# 1. Delete the error-location prefix (`psql:<stdin>:12:` or `ysqlsh:/tmp/x.sql:12:`), which
#    differs between stdin and `-f` execution.
#
# 2. A trailing ` at character N`. Under VERBOSITY terse psql still appends the cursor POSITION for
#    errors that carry one -- and N is a byte offset into the statement text, so re-indenting a
#    query moves it. Pinning it would make these goldens depend on the whitespace of the .sql file
#    beside them, which is a property of nothing. The `#[pg_test(error = ...)]` attributes in
#    lib.rs do not carry it either, so keeping it would also make the port less faithful, not more.
norm() {
    sed -E -e 's/^(psql|ysqlsh):[^:]*:[0-9]+:[[:space:]]?//' \
           -e 's/ at character [0-9]+$//'
}

cleanup_server_case() {
    local cleanup=$1
    local directory=$2
    local log=$3

    case "$directory" in
        /tmp/kmoney-suite.*) ;;
        *)
            echo "run-suite[$LABEL]: refusing cleanup of unexpected path: $directory" >&2
            return 2
            ;;
    esac

    # Pass the validated path as a shell assignment before the fixed cleanup script. `%q`
    # preserves it as one value; server-exec is required to invoke bash.
    # shellcheck disable=SC2086 # SERVER_EXEC is a command line; splitting is the point
    { printf 'KMONEY_SUITE_DIR=%q\n' "$directory"; cat "$cleanup"; } | $SERVER_EXEC > "$log" 2>&1
}

pass=0
fail=0
failed_cases=()

for c in "${CASES[@]}"; do
    sql="$SUITE/sql/$c.sql"
    exp="$SUITE/expected/$c.out"
    got="$OUTDIR/$c.out"

    if [ ! -f "$sql" ]; then
        echo "run-suite[$LABEL]: FAIL $c -- no sql/$c.sql"
        fail=$((fail+1)); failed_cases+=("$c:no-sql"); continue
    fi
    # A case with no golden is NOT a pass and NOT a skip. This is the rule native-driver-test.sh
    # learned the hard way: a harness that treats "nothing to compare against" as success
    # reports green for exactly the cases nobody finished writing.
    if [ ! -f "$exp" ]; then
        echo "run-suite[$LABEL]: FAIL $c -- no expected/$c.out (a case without a golden proves nothing)"
        fail=$((fail+1)); failed_cases+=("$c:no-golden"); continue
    fi

    # Optional per-case server-side setup, fed to the server's shell on stdin. The wire case
    # needs deliberately malformed binary-COPY files to exist on the SERVER's filesystem, and
    # SQL has no primitive that writes arbitrary bytes to a file.
    setup="$SUITE/sql/$c.setup.sh"
    cleanup="$SUITE/sql/$c.cleanup.sh"
    server_directory=""
    if [ -f "$setup" ]; then
        if [ -z "$SERVER_EXEC" ]; then
            echo "run-suite[$LABEL]: FAIL $c -- needs sql/$c.setup.sh but no --server-exec was given"
            fail=$((fail+1)); failed_cases+=("$c:no-server-exec"); continue
        fi
        # shellcheck disable=SC2086 # SERVER_EXEC is a command line; splitting is the point
        if ! $SERVER_EXEC < "$setup" > "$OUTDIR/$c.setup.log" 2>&1; then
            echo "run-suite[$LABEL]: FAIL $c -- server-side setup failed:"
            sed 's/^/    /' "$OUTDIR/$c.setup.log"
            server_directory=$(sed -n 's/^KMONEY_SUITE_DIR=//p' "$OUTDIR/$c.setup.log" | tail -1)
            if [ -n "$server_directory" ] && [ -f "$cleanup" ]; then
                cleanup_server_case "$cleanup" "$server_directory" "$OUTDIR/$c.cleanup.log" || true
            fi
            fail=$((fail+1)); failed_cases+=("$c:setup"); continue
        fi
        mapfile -t server_directories < <(sed -n 's/^KMONEY_SUITE_DIR=//p' "$OUTDIR/$c.setup.log")
        if [ "${#server_directories[@]}" -ne 1 ]; then
            echo "run-suite[$LABEL]: FAIL $c -- setup must report exactly one KMONEY_SUITE_DIR"
            fail=$((fail+1)); failed_cases+=("$c:setup-directory"); continue
        fi
        server_directory="${server_directories[0]}"
        case "$server_directory" in
            /tmp/kmoney-suite.*) ;;
            *)
                echo "run-suite[$LABEL]: FAIL $c -- setup reported unexpected directory: $server_directory"
                fail=$((fail+1)); failed_cases+=("$c:setup-directory"); continue
                ;;
        esac
        if [ ! -f "$cleanup" ]; then
            echo "run-suite[$LABEL]: FAIL $c -- setup exists but sql/$c.cleanup.sh is missing"
            fail=$((fail+1)); failed_cases+=("$c:no-cleanup"); continue
        fi
    fi

    # ON_ERROR_STOP=0: many cases exist to provoke an error whose TEXT is the assertion. Under
    # it an expected SQL error does NOT set the client's exit status, so a nonzero status is
    # structural -- could not connect, file unreadable, backend died -- and is its own failure.
    set +e
    # shellcheck disable=SC2086 # CLIENT is a command line; splitting is the point
    if [ -n "$server_directory" ]; then
        $CLIENT -X -q -v ON_ERROR_STOP=0 -v "kmoney_suite_dir=$server_directory" < "$sql" > "$got" 2>&1
    else
        $CLIENT -X -q -v ON_ERROR_STOP=0 < "$sql" > "$got" 2>&1
    fi
    status=$?
    set -e

    if [ -n "$server_directory" ] &&
       ! cleanup_server_case "$cleanup" "$server_directory" "$OUTDIR/$c.cleanup.log"; then
        echo "run-suite[$LABEL]: FAIL $c -- server-side cleanup failed:"
        sed 's/^/    /' "$OUTDIR/$c.cleanup.log"
        fail=$((fail+1)); failed_cases+=("$c:cleanup"); continue
    fi

    if [ "$status" -ne 0 ]; then
        echo "run-suite[$LABEL]: FAIL $c -- client exited $status; under ON_ERROR_STOP=0 that is structural, not an expected SQL error"
        tail -5 "$got" | sed 's/^/    /'
        fail=$((fail+1)); failed_cases+=("$c:client-$status"); continue
    fi

    # Reached the end, EXACTLY once. "At least once" would accept a file holding two half-runs;
    # zero would accept a case that died after printing plausible-looking rows.
    complete="$(grep -c "^== CASE COMPLETE: $c ==$" "$got" || true)"
    if [ "$complete" != "1" ]; then
        echo "run-suite[$LABEL]: FAIL $c -- expected exactly 1 '== CASE COMPLETE: $c ==', found $complete"
        fail=$((fail+1)); failed_cases+=("$c:incomplete"); continue
    fi

    if diff -u <(norm < "$exp") <(norm < "$got") > "$OUTDIR/$c.diff"; then
        rm -f "$OUTDIR/$c.diff"
        echo "run-suite[$LABEL]: ok   $c"
        pass=$((pass+1))
    else
        echo "run-suite[$LABEL]: FAIL $c -- output differs from expected/$c.out:"
        sed 's/^/    /' "$OUTDIR/$c.diff"
        fail=$((fail+1)); failed_cases+=("$c:diff")
    fi
done

echo
if [ "$fail" -eq 0 ]; then
    echo "run-suite[$LABEL]: OK -- $pass/$((pass+fail)) cases match their golden output"
else
    echo "run-suite[$LABEL]: FAILED -- $fail of $((pass+fail)) cases: ${failed_cases[*]}"
    exit 1
fi
