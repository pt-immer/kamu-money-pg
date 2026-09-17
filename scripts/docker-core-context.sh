#!/usr/bin/env bash
# Source this file before a lane Docker build. It packages kamu-money-core exactly
# as Cargo would publish it and exposes that small, normalized directory as a
# named build context. The main Docker context remains the isolated money-pg lane.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "docker-core-context: source this file from a Docker build caller" >&2
    exit 2
fi

DOCKER_CORE_SCRIPT_DIR="$(
    cd "$(dirname "${BASH_SOURCE[0]}")" || exit
    pwd -P
)"
DOCKER_CORE_LANE_ROOT="$(cd "$DOCKER_CORE_SCRIPT_DIR/.." && pwd -P)"
DOCKER_CORE_REPO_ROOT="$(cd "$DOCKER_CORE_LANE_ROOT/../.." && pwd -P)"
DOCKER_CORE_MANIFEST="$DOCKER_CORE_REPO_ROOT/crates/money-core/Cargo.toml"

KMONEY_USE_LOCAL_CORE="${KMONEY_USE_LOCAL_CORE:-1}"
case "$KMONEY_USE_LOCAL_CORE" in
    0 | 1) ;;
    *)
        echo "docker-core-context: KMONEY_USE_LOCAL_CORE must be 0 or 1, got '$KMONEY_USE_LOCAL_CORE'" >&2
        return 2
        ;;
esac

# The `[package]` version only. A bare `version =` match would take a dependency's.
DOCKER_CORE_VERSION="$(
    awk '/^\[package\]/ { in_package = 1; next }
         /^\[/          { in_package = 0 }
         in_package && /^version[[:space:]]*=/ {
             gsub(/^version[[:space:]]*=[[:space:]]*"|"[[:space:]]*$/, "")
             print
             exit
         }' "$DOCKER_CORE_MANIFEST"
)"
[ -n "$DOCKER_CORE_VERSION" ] || {
    echo "docker-core-context: no [package] version in $DOCKER_CORE_MANIFEST" >&2
    return 2
}

(
    cd "$DOCKER_CORE_REPO_ROOT" || exit
    cargo package \
        --manifest-path "$DOCKER_CORE_REPO_ROOT/Cargo.toml" \
        -p kamu-money-core \
        --allow-dirty \
        --locked
)

DOCKER_CORE_PACKAGE="$DOCKER_CORE_REPO_ROOT/target/package/kamu-money-core-$DOCKER_CORE_VERSION"

# `cargo package` records the HEAD sha1 in `.cargo_vcs_info.json`, so the packaged directory's
# content changes on EVERY COMMIT even when kamu-money-core does not. This directory is copied into
# both images above their dependency layer, so leaving the file in place gives that layer a cache
# key that can never repeat: a second commit on a branch recompiles the whole pgrx graph, and the
# `actions/cache` entry still reports a hit because its key hashes manifests rather than this.
#
# Nothing consumes the file. Cargo reads a `[patch]` path dependency from its manifest and sources;
# the provenance stanza exists for a published `.crate`, which this is not.
rm -f "$DOCKER_CORE_PACKAGE/.cargo_vcs_info.json"

for required in Cargo.toml tests/pg_native_column.rs; do
    if [ ! -f "$DOCKER_CORE_PACKAGE/$required" ]; then
        echo "docker-core-context: package is missing $required: $DOCKER_CORE_PACKAGE" >&2
        return 1
    fi
done

# shellcheck disable=SC2034 # exported to each sourcing Docker build caller
KMONEY_CORE_DOCKER_ARGS=(
    --build-context "kamu-money-core=$DOCKER_CORE_PACKAGE"
    --build-arg "KMONEY_USE_LOCAL_CORE=$KMONEY_USE_LOCAL_CORE"
)
