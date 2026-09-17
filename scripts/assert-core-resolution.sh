#!/usr/bin/env bash
# Assert that Cargo resolved kamu-money-core the way this image intends, at the version this tree
# carries.
#
#   bash scripts/assert-core-resolution.sh local|registry [core-dir]
#
# The lane's container builds carry a named Docker context holding Cargo's normalized
# kamu-money-core package and append a `[patch.crates-io]` entry pointing at it. PASSING that
# context is not the same as USING it. A patch offering a version `Cargo.lock` does not pin is
# ignored: Cargo prints `patch ... was not used in the crate graph` and compiles the published
# crate instead, and the build succeeds either way.
#
# That is not hypothetical. A dependency bump ran bare `cargo update` in this lane, which re-locked
# the patched kamu-money-core entry to the registry. Every PostgreSQL and YugabyteDB container
# suite then went on testing the PUBLISHED crate while its caller believed it was testing the tree,
# and nothing said so -- the repository's guard checks that the context is passed, which it was.
#
# THE VERSION IS CHECKED IN BOTH DIRECTIONS, and that is not decoration. The lane's lockfile
# records kamu-money-core as a patched entry, which carries no `source` and no `checksum`, so the
# release proof (`KMONEY_USE_LOCAL_CORE=0`, no patch) has nothing pinning it: Cargo re-resolves
# `kamu-money-core = "0.1"` against crates.io at build time. Without the assertion below,
# `gate-pg-release` at a fixed commit certifies 0.1.2 today and whatever is published tomorrow,
# with no check failing and no diff to look at. The expected version is READ FROM THE PACKAGED
# CONTEXT rather than written here, so it cannot drift from the crate it describes.
set -euo pipefail

WANT="${1:-}"
CORE_DIR="${2:-/opt/kamu-money-core}"
case "$WANT" in
    local | registry) ;;
    *)
        echo "assert-core-resolution: usage: assert-core-resolution.sh local|registry [core-dir]" >&2
        exit 2
        ;;
esac

CORE_MANIFEST="$CORE_DIR/Cargo.toml"
[ -f "$CORE_MANIFEST" ] || {
    echo "assert-core-resolution: no kamu-money-core manifest at $CORE_MANIFEST." >&2
    echo "assert-core-resolution: the normalized core context is what this build compares against," >&2
    echo "assert-core-resolution: so its absence is a build misconfiguration, not a lockfile fault." >&2
    exit 2
}

# The `[package]` version only. A bare `version =` match would take a dependency's.
EXPECTED="$(
    awk '/^\[package\]/ { in_package = 1; next }
         /^\[/          { in_package = 0 }
         in_package && /^version[[:space:]]*=/ {
             gsub(/^version[[:space:]]*=[[:space:]]*"|"[[:space:]]*$/, "")
             print
             exit
         }' "$CORE_MANIFEST"
)"
[ -n "$EXPECTED" ] || {
    echo "assert-core-resolution: could not read a [package] version from $CORE_MANIFEST" >&2
    exit 2
}

# A resolution failure is NOT a resolution answer. Collapsing the two would hand the operator a
# lockfile rewrite as the remedy for a transient index fetch, and bury the real error further up
# the build log. stderr is left to flow there.
set +e
TREE="$(cargo tree --invert kamu-money-core --depth 0)"
STATUS=$?
set -e
if [ "$STATUS" -ne 0 ]; then
    echo "assert-core-resolution: \`cargo tree\` FAILED (exit $STATUS); its diagnostic is above." >&2
    echo "assert-core-resolution: that is a resolution, network or toolchain fault -- NOT a stale" >&2
    echo "assert-core-resolution: lockfile. Do not re-lock in response to it." >&2
    exit 1
fi

RESOLVED="${TREE%%$'\n'*}"
[ -n "$RESOLVED" ] || {
    echo "assert-core-resolution: kamu-money-core is not in the resolved graph at all" >&2
    exit 1
}

# `cargo tree` renders a path source as a trailing parenthesised directory and a registry source
# with none. Testing for A path rather than one hardcoded spelling of it keeps this from reading a
# moved or differently-mounted local checkout as "resolved from crates.io" -- which would let the
# release proof certify the working tree while reporting the published crate.
RESOLVED_PATH=""
case "$RESOLVED" in
    *\ \(*\)) RESOLVED_PATH="${RESOLVED##*(}"; RESOLVED_PATH="${RESOLVED_PATH%)}" ;;
esac
RESOLVED_VERSION="$(printf '%s\n' "$RESOLVED" | awk '{ print $2 }')"
RESOLVED_VERSION="${RESOLVED_VERSION#v}"

if [ "$WANT" = local ] && [ -z "$RESOLVED_PATH" ]; then
    echo "assert-core-resolution: REFUSING -- the normalized kamu-money-core context is present" >&2
    echo "assert-core-resolution: and patched in, but Cargo resolved '$RESOLVED' from the registry." >&2
    echo "assert-core-resolution: A patch offering a version Cargo.lock does not pin is IGNORED," >&2
    echo "assert-core-resolution: and this build would then test the published crate. Re-lock the" >&2
    echo "assert-core-resolution: lane with the patch active: just pg core-relock." >&2
    exit 1
fi

if [ "$WANT" = registry ] && [ -n "$RESOLVED_PATH" ]; then
    echo "assert-core-resolution: REFUSING -- the release proof must resolve kamu-money-core from" >&2
    echo "assert-core-resolution: crates.io, but Cargo resolved it from '$RESOLVED_PATH'." >&2
    exit 1
fi

if [ "$RESOLVED_VERSION" != "$EXPECTED" ]; then
    echo "assert-core-resolution: REFUSING -- resolved kamu-money-core $RESOLVED_VERSION, but this" >&2
    echo "assert-core-resolution: tree carries $EXPECTED." >&2
    if [ "$WANT" = registry ]; then
        echo "assert-core-resolution: the lane's lockfile records kamu-money-core as a PATCHED" >&2
        echo "assert-core-resolution: entry, which pins no version for a build with no patch, so" >&2
        echo "assert-core-resolution: crates.io decides what this release artifact links. Publish" >&2
        echo "assert-core-resolution: $EXPECTED, or build the release proof from a commit whose" >&2
        echo "assert-core-resolution: kamu-money-core is already published." >&2
    else
        echo "assert-core-resolution: re-lock the lane with the patch active: just pg core-relock." >&2
    fi
    exit 1
fi

echo "assert-core-resolution: kamu-money-core resolved ${WANT} at ${RESOLVED_VERSION} -- ${RESOLVED}"
