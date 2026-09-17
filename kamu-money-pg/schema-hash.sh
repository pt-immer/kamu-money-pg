#!/usr/bin/env bash
# A stable fingerprint of the SQL this extension generates.
#
#   kamu-money-pg/schema-hash.sh [pg_major] [expected_hash]
#
# pgrx may emit unchanged SQL entities in different orders. Normalize provenance and ordering
# before hashing so the fingerprint tracks the SQL surface rather than generator order.
#
# The set of objects is stable. Strip the source-position comments pgrx embeds:
#
#     -- <any source file>.rs:<line>
#     -- kmoney::<item>
#     CREATE SCHEMA ...; /* kmoney::<module> */
#
# Both encode source position, so a refactor changes them by construction and
# neither says anything about the SQL contract.
#
# Match source paths generically, collapse each object to one line, sort the lines, then hash.
#
# WHAT IT DOES NOT PROVE. That the extension works: it is a statement about generated SQL text,
# not about behaviour. `just test-pg` is what proves behaviour, and the in-backend `#[pg_test]`
# suite cannot be replaced by this. This answers exactly one question -- "did the SQL surface
# move?" -- which is the question a module split needs answered and cannot answer by reading.
set -euo pipefail
cd "$(dirname "$0")"

# cargo-pgrx launches its own Cargo subprocesses and does not forward outer `--config` flags.
# Point its standard `CARGO` hook at a proxy that injects the host-only sibling patch into each
# subprocess. Calling cargo-pgrx directly avoids Cargo overwriting that hook when it starts the
# external subcommand.
KMONEY_CORE_PATH="$(cd ../../../crates/money-core && pwd -P)"
export KMONEY_CORE_PATH
export RUSTUP_TOOLCHAIN
RUSTUP_TOOLCHAIN="$(rustup show active-toolchain | awk '{print $1}')"
export KMONEY_REAL_CARGO
KMONEY_REAL_CARGO="$(rustup which cargo)"
CARGO="$(cd ../scripts && pwd -P)/cargo-with-core-patch.sh"
export CARGO

PG="${1:-18}"
EXPECT="${2:-}"
# Extra cargo features. `pg_test` is the one that matters: the in-backend test suite is behind
# it, so the DEFAULT surface cannot see the test functions at all. Splitting the test module
# needs an oracle too -- "the tests still pass" proves the ones that ran are green, not that the
# same generated test surface still exists -- and this is it.
FEATURES="${3:-}"

case "$PG" in
    ''|*[!0-9]*) echo "schema-hash: pg major must be digits, got '$PG'" >&2; exit 2 ;;
esac

FEATURE_ARGS=()
if [ -n "$FEATURES" ]; then
    FEATURE_ARGS=(--features "$FEATURES")
fi

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; return 0; }
trap cleanup EXIT INT TERM HUP
export CARGO_TARGET_DIR="$WORK/target"

if ! cargo-pgrx pgrx schema "pg${PG}" "${FEATURE_ARGS[@]}" --out "$WORK/schema.sql" >"$WORK/gen.log" 2>&1; then
    echo "schema-hash: 'cargo pgrx schema pg${PG} ${FEATURES}' failed" >&2
    tail -30 "$WORK/gen.log" >&2
    exit 1
fi

# One line per SQL object, provenance stripped, sorted. `\001` as the record separator because
# the delimiter is a literal pgrx emits; `\037` (unit separator) joins the lines of one object,
# so a sort is over whole objects rather than over their individual lines.
normalized() {
    sed 's|/\* <begin connected objects> \*/|\x01|g' "$WORK/schema.sql" \
        | gawk -v RS=$'\001' '
        {
            out = ""
            n = split($0, line, "\n")
            for (i = 1; i <= n; i++) {
                s = line[i]
                sub(/^[[:space:]]+/, "", s)
                sub(/[[:space:]]+$/, "", s)
                if (s == "") continue
                # The two provenance comments: source path + line, and the Rust item path.
                # ANY .rs path, not just lib.rs -- a module split moves items into new files.
                if (s ~ /^-- [A-Za-z0-9_.\/-]+\.rs:[0-9]+$/) continue
                if (s ~ /^-- kmoney::/) continue
                sub(/[[:space:]]+\/\* kmoney::[^*]+ \*\/$/, "", s)
                if (s == "/* </end connected objects> */") continue
                out = (out == "" ? s : out "\037" s)
            }
            # Drops pgrx@version preamble and any stray comment-only record: this hashes the SQL
            # SURFACE, and a record that creates nothing is not part of it.
            if (out ~ /CREATE|ALTER|COMMENT|GRANT|INSERT|DROP/) print out
        }' \
        | LC_ALL=C sort
}

COUNT="$(normalized | wc -l)"
HASH="$(normalized | sha256sum | cut -d' ' -f1)"

if [ "$COUNT" -eq 0 ]; then
    echo "schema-hash: normalized to ZERO objects -- the generator or this filter is broken" >&2
    exit 1
fi

echo "schema-hash: pg${PG} objects=${COUNT} sha256=${HASH}"

if [ -n "$EXPECT" ]; then
    if [ "$HASH" != "$EXPECT" ]; then
        echo "schema-hash: MISMATCH" >&2
        echo "  expected ${EXPECT}" >&2
        echo "  got      ${HASH}" >&2
        echo "The generated SQL surface MOVED. For a refactor that was supposed to be pure" >&2
        echo "relocation, that is the refactor being wrong -- not this check being noisy." >&2
        exit 1
    fi
    echo "schema-hash: matches the expected surface"
fi
