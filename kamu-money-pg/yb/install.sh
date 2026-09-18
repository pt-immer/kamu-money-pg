#!/usr/bin/env bash
# Get `kmoney` onto a YugabyteDB node, and PROVE it is the right bytes. Sourced, not executed.
#
#   source kamu-money-pg/yb/install.sh
#   yb_ensure_extension "$CONTAINER" [artifact-dir]   # -> YB_INSTALL_MODE=baked|copied
#   yb_extract_artifact_from_image "$IMAGE" out/dir   # pull the triplet OUT of a node image
#
# Two installation modes share one verifier:
#
#   * COPIED -- `docker cp` the triplet into a container booted from the stock YugabyteDB image.
#     This is what a harness needs (it is also the only way the missing-library negative control
#     has something to remove), and it is emphatically NOT how the extension reaches production.
#   * BAKED  -- the node image already carries it (`just yb-node-image`). Nothing is installed onto
#     a running node; a node either boots from the image or does not exist. This IS production.
#
# `YB_REQUIRE_BAKED=1` makes the deployment artifact itself the test subject. Under it, `docker cp`
# is not a fallback; a node that
# does not already carry the extension is a failure, so a release run cannot quietly succeed by
# installing onto the stock image after the node image failed to provide it. That is the difference
# between "the extension works" and "the artifact we ship works".
#
# EITHER WAY THE HASH IS CHECKED, PER NODE. "The DDL propagates, the shared library does not" is
# the failure the cluster suite exists to surface, and a copy loop that reports success because
# `docker cp` exited 0 is not evidence that the bytes arrived intact on node 3 of 5.
#
# `set -euo pipefail` is deliberately NOT set here: sourced into scripts that already set it.

# The extension triplet is resolved by ONE function, by exact name, against a manifest.
# shellcheck source=kamu-money-pg/yb/artifact.sh
source "$(dirname "${BASH_SOURCE[0]}")/artifact.sh"

YB_LIB=/home/yugabyte/postgres/lib/kmoney.so
YB_EXTDIR=/home/yugabyte/postgres/share/extension
# The manifest the node image carries, renamed on the way in so it cannot collide with an
# extension file. It is the image's own statement about what it holds.
YB_IMAGE_MANIFEST="$YB_EXTDIR/kmoney-ARTIFACT-MANIFEST.txt"

# "baked" or "copied", set by yb_ensure_extension. Release evidence records which.
# shellcheck disable=SC2034 # set here for the SOURCING script
YB_INSTALL_MODE=""

# The sha256 of kmoney.so as it exists ON THE NODE, whichever way it got there.
# shellcheck disable=SC2034 # ditto
YB_INSTALL_SHA=""

# Ensure ONE container carries the extension, and verify it by hash.
#
# The expected hash for a baked image comes from the manifest INSIDE the image, never from the
# host's out/ directory. Those are separate builds, and pgrx's generated SQL is not byte-stable
# across them; comparing them would make this a reproducible-builds assertion
# it has no business making, and would fail for a reason that has nothing to do with the node.
yb_ensure_extension() {
    local node="$1" art="${2:-${KMONEY_RUN_ROOT:-kamu-money-pg/yb/out}}"
    local want got

    if docker exec "$node" test -f "$YB_LIB" 2>/dev/null; then
        YB_INSTALL_MODE="baked"
        want="$(docker exec "$node" awk '$2 == "kmoney.so" { print $1 }' \
            "$YB_IMAGE_MANIFEST" 2>/dev/null || true)"
        if [ -z "$want" ]; then
            echo "install: $node carries kmoney.so but no manifest entry for it." >&2
            echo "install: an image that cannot say what it is carrying is not release evidence," >&2
            echo "install: whatever the library happens to compute. Rebuild with 'just yb-node-image'." >&2
            return 1
        fi
    elif [ "${YB_REQUIRE_BAKED:-0}" = "1" ]; then
        # THE WHOLE POINT. Falling back to `docker cp` here would produce a green run against a
        # harness-installed extension while the run announced the node image it booted -- a pass
        # claiming an artifact that was never exercised.
        echo "install: $node does not carry kmoney, and YB_REQUIRE_BAKED=1." >&2
        echo "install: this run must exercise the DEPLOYABLE node image, so installing onto a" >&2
        echo "install: running node is not a fallback here -- it is the thing being ruled out." >&2
        echo "install: build it with 'just yb-node-image' and boot the suite from that image." >&2
        return 1
    else
        YB_INSTALL_MODE="copied"
        yb_resolve_artifacts "$art" || return 2
        docker cp "$YB_ART_SO"  "$node:$YB_LIB"
        docker cp "$YB_ART_CTL" "$node:$YB_EXTDIR/kmoney.control"
        docker cp "$YB_ART_SQL" "$node:$YB_EXTDIR/$(basename "$YB_ART_SQL")"
        want="$(sha256sum "$YB_ART_SO" | cut -d' ' -f1)"
    fi

    got="$(docker exec "$node" sha256sum "$YB_LIB" 2>/dev/null | cut -d' ' -f1 || true)"
    if [ "$got" != "$want" ]; then
        echo "install: $node carries the WRONG kmoney.so ($YB_INSTALL_MODE)" >&2
        echo "install:   on the node $got" >&2
        echo "install:   expected    $want" >&2
        return 1
    fi
    # shellcheck disable=SC2034 # read by the SOURCING script (release evidence, cross-node compare)
    YB_INSTALL_SHA="$got"
}

# Put kmoney.so back on a node the missing-library negative control removed it from, taking the
# bytes from a node that still has them.
#
# FROM A DONOR NODE, NOT FROM THE HOST'S out/. The negative control's job is to leave the cluster
# exactly as it found it, and under a baked image the host may hold no artifact at all -- the old
# `docker cp "$YB_ART_SO"` restore only worked because every run happened to be a copied one. A
# donor is always available for the same reason the control is meaningful: the OTHER nodes still
# have the library. It is also the stronger restore, because it puts back the bytes this cluster
# was actually running rather than whatever is in a directory on the host.
yb_restore_extension_on() {
    local target="$1" donor="$2" tmp rc=0
    tmp="$(mktemp -d)"
    docker cp "$donor:$YB_LIB" "$tmp/kmoney.so" >/dev/null &&
        docker cp "$tmp/kmoney.so" "$target:$YB_LIB" || rc=1
    rm -rf "$tmp"
    [ "$rc" -eq 0 ] || { echo "install: could not restore kmoney.so onto $target" >&2; return 1; }

    local want got
    want="$(docker exec "$donor" sha256sum "$YB_LIB" | cut -d' ' -f1)"
    got="$(docker exec "$target" sha256sum "$YB_LIB" 2>/dev/null | cut -d' ' -f1 || true)"
    if [ "$got" != "$want" ]; then
        echo "install: restored kmoney.so on $target does not match $donor" >&2
        return 1
    fi
    echo "install: restored kmoney.so on $target from $donor"
}

# Pull the extension triplet and its manifest OUT of a built node image.
#
# WHY EXTRACT RATHER THAN BUILD THE `artifact` TARGET SEPARATELY. pgrx's generated install SQL is
# not reproducible: three builds from the same revision produced three different SQL hashes (the
# `.so` and control file were stable, and the differences were reorderings of independent pgrx
# "connected object" blocks). So `--target artifact` and `--target node`, built separately, can
# disagree -- and then the loose files a suite copies in are not the files the image ships, which
# is precisely the substitution the whole provenance chain exists to prevent.
#
# Copying them out of the finished image makes them the image's own bytes BY CONSTRUCTION. One
# build, one set of bytes, and the manifest that comes with them is the one the image verified
# against itself at build time.
yb_extract_artifact_from_image() {
    local image="$1" dir="${2:-${KMONEY_RUN_ROOT:-kamu-money-pg/yb/out}}" cid rc=0
    mkdir -p "$dir"
    # `docker create` without starting: this only needs a filesystem to copy from.
    cid="$(docker create "$image" /bin/true)" || return 1
    # NOT `trap ... RETURN`. A trap set inside a function is GLOBAL in bash, so it would fire again
    # on every later function return in the whole run -- and this one names a container that no
    # longer exists. Explicit teardown, on both paths, where the scope is visible.
    _yb_extract_into "$cid" "$dir" || rc=$?
    docker rm -f "$cid" >/dev/null 2>&1 || true
    return "$rc"
}

_yb_extract_into() {
    local cid="$1" dir="$2" version
    docker cp "$cid:$YB_LIB"                   "$dir/kmoney.so"             >/dev/null || return 1
    docker cp "$cid:$YB_EXTDIR/kmoney.control" "$dir/kmoney.control"        >/dev/null || return 1
    docker cp "$cid:$YB_IMAGE_MANIFEST"        "$dir/$YB_ART_MANIFEST_NAME" >/dev/null || return 1
    # The version is the only part of the name not known in advance, so read it from the control
    # file that just came out of the same image rather than guessing.
    version="$(sed -n "s/^[[:space:]]*default_version[[:space:]]*=[[:space:]]*'\([^']*\)'.*/\1/p" \
        "$dir/kmoney.control" | head -1)"
    [ -n "$version" ] || {
        echo "install: extracted control file declares no default_version" >&2
        return 1
    }
    docker cp "$cid:$YB_EXTDIR/kmoney--$version.sql" "$dir/kmoney--$version.sql" >/dev/null || return 1
    echo "install: extracted kmoney $version from the node image into $dir" >&2
}
