#!/usr/bin/env bash
# Build THE DEPLOYABLE NODE IMAGE -- YugabyteDB with `kmoney` baked in -- and print its image ID
# on stdout. Everything else goes to stderr, because callers consume this as
# `NODE_IMAGE="$(node-image.sh "$YB_REF")"`. Same contract as yb-image.sh, for the same reason.
#
#   kamu-money-pg/yb/node-image.sh <resolved-base-ref>
#
# THE BASE REF IS AN ARGUMENT, NOT SOMETHING THIS RESOLVES. A release run resolves the YugabyteDB
# identity exactly once and hands the same immutable reference to every stage; a script that
# resolved its own could silently straddle a retag and produce a node image built on a different
# base from the one the rest of the run tested. So it is type-checked here rather than trusted:
# `yb-image.sh` prints `repo@sha256:...` (or a bare image ID for a locally-built base), and a
# mutable tag contains no `sha256:`.
#
# WHY AN IMAGE AT ALL. Installing onto running nodes cannot survive a node being replaced and
# requires enumerating every tserver -- including read replicas, which are tservers too. Baking it
# in makes "is the extension on every node?" the same question as "is every node on digest D?",
# which the orchestrator already answers, identically for primaries and replicas, RF3 and RF5.
#
# WHAT THIS PRINTS IS A LOCAL IMAGE ID, NOT A REGISTRY DIGEST. They are different things and the
# difference matters at deploy time: an orchestrator pulls `repo@sha256:...`, which only exists
# once the image has been PUSHED. Publishing belongs to the platform release path, not here. This
# ID is what binds the release evidence to the exact bytes that were tested; the registry digest
# is recorded against it when the image is published.
set -euo pipefail
cd "$(dirname "$0")/../.."   # repo root
# shellcheck source=scripts/docker-core-context.sh
source ./scripts/docker-core-context.sh

BASE_REF="${1:-}"
if [ -z "$BASE_REF" ]; then
    echo "node-image: usage: node-image.sh <resolved-base-ref>" >&2
    echo "node-image: resolve it with kamu-money-pg/yb/yb-image.sh first." >&2
    exit 2
fi
case "$BASE_REF" in
    *sha256:*) ;;
    *)
        echo "node-image: '$BASE_REF' is not an immutable reference." >&2
        echo "node-image: the base identity must be resolved ONCE by the caller and passed in, so" >&2
        echo "node-image: that the image this builds sits on the same base every other stage used." >&2
        exit 2 ;;
esac

# From Cargo.toml, NOT from kmoney.control. The tracked control file is a pgrx TEMPLATE carrying
# `default_version = '@CARGO_VERSION@'`; the substitution happens at package time, so reading it
# here produced the tag `kmoney-yugabyte:@CARGO_VERSION@` and docker rejected it. The manifest
# version is what pgrx substitutes, so this is the same string by construction.
VERSION="$(sed -n '/^\[package\]/,/^\[/ s/^version = "\([^"]*\)".*/\1/p' \
    kamu-money-pg/Cargo.toml | head -1)"
[ -n "$VERSION" ] || {
    echo "node-image: could not read version from kamu-money-pg/Cargo.toml" >&2
    exit 1
}

IID="$(mktemp)"
cleanup() { rm -f "$IID"; return 0; }
trap cleanup EXIT INT TERM HUP

echo "node-image: building kmoney-yugabyte:$VERSION on $BASE_REF" >&2
docker build "${KMONEY_CORE_DOCKER_ARGS[@]}" \
    -f kamu-money-pg/yb/Dockerfile --target node \
    --build-arg YB_IMAGE="$BASE_REF" --iidfile "$IID" \
    --build-arg KMONEY_CACHE_ID="${KMONEY_CACHE_ID:-shared}" \
    -t "kmoney-yugabyte:${VERSION}" . >&2

ID="$(cat "$IID")"
echo "node-image: kmoney-yugabyte:$VERSION is $ID" >&2
printf '%s\n' "$ID"
