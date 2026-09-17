#!/usr/bin/env bash
# Resolve one coherent `kmoney` extension triplet. Sourced, not executed.
#
#   source kamu-money-pg/yb/artifact.sh
#   yb_resolve_artifacts kamu-money-pg/yb/out
#   # -> YB_ART_SO / YB_ART_CTL / YB_ART_SQL / YB_ART_VERSION / YB_ART_DIR / YB_ART_VERIFIED
#
# Resolution requires exact names in one directory, one install script, agreement between the
# control file's `default_version` and that script's filename, and matching hashes in
# ARTIFACT-MANIFEST.txt. `YB_ART_ALLOW_UNVERIFIED=1` permits a non-evidence developer run and sets
# `YB_ART_VERIFIED=no`.
#
# `set -euo pipefail` is deliberately NOT set here: this file is sourced into scripts that already
# set it, and shell options set from a sourced file change the caller's shell.

# shellcheck disable=SC2034 # set here for the SOURCING script; unused within this file by design
YB_ART_DIR=""
# shellcheck disable=SC2034 # ditto
YB_ART_SO=""
# shellcheck disable=SC2034 # ditto
YB_ART_CTL=""
# shellcheck disable=SC2034 # ditto
YB_ART_SQL=""
# shellcheck disable=SC2034 # ditto
YB_ART_VERSION=""
# "yes" once every byte matched ARTIFACT-MANIFEST.txt; "no" only on the explicitly-requested
# non-evidence path. A caller that cares whether it is holding verified bytes reads this flag
# rather than assuming the resolve implied a check.
# shellcheck disable=SC2034 # ditto
YB_ART_VERIFIED=""

# The manifest the YB Dockerfile writes beside the artifact. It is `sha256sum`'s own format, so
# verification is `sha256sum -c` rather than a hand-rolled comparison loop.
YB_ART_MANIFEST_NAME="ARTIFACT-MANIFEST.txt"

yb_resolve_artifacts() {
    local dir="${1:-${KMONEY_RUN_ROOT:-kamu-money-pg/yb/out}}"

    if [ ! -d "$dir" ]; then
        echo "artifact: $dir does not exist -- run 'just yb-build' first" >&2
        return 2
    fi

    local so="$dir/kmoney.so"
    local ctl="$dir/kmoney.control"

    local missing=()
    [ -f "$so" ]  || missing+=("kmoney.so")
    [ -f "$ctl" ] || missing+=("kmoney.control")

    # -maxdepth 1: never a recursive search of a shared output tree. The version is the only part
    # of any name that is not known in advance, which is why this one entry is a glob at all.
    local sqls=()
    while IFS= read -r line; do
        [ -n "$line" ] && sqls+=("$line")
    done < <(find "$dir" -maxdepth 1 -type f -name 'kmoney--*.sql' | sort)

    [ "${#sqls[@]}" -eq 0 ] && missing+=("kmoney--<version>.sql")

    if [ "${#missing[@]}" -gt 0 ]; then
        echo "artifact: missing under $dir: ${missing[*]}" >&2
        echo "artifact: build it with 'just yb-build' (writes the triplet plus $YB_ART_MANIFEST_NAME)" >&2
        return 2
    fi

    # More than one install script is not a version choice this harness is entitled to make. A
    # release runs against ONE extension version, and picking silently is how a run ends up
    # certifying a version nobody asked about.
    if [ "${#sqls[@]}" -gt 1 ]; then
        echo "artifact: $dir holds ${#sqls[@]} install scripts, so the version is ambiguous:" >&2
        printf 'artifact:   %s\n' "${sqls[@]}" >&2
        echo "artifact: build into an empty directory -- this harness will not choose for you." >&2
        return 2
    fi

    local sql="${sqls[0]}"

    # The version stated by the FILENAME and the version stated INSIDE the control file must be the
    # same string. `CREATE EXTENSION` uses default_version to decide which script to run, so a
    # disagreement means the script that runs is not the script this harness checked.
    local file_version control_version
    file_version="$(basename "$sql")"
    file_version="${file_version#kmoney--}"
    file_version="${file_version%.sql}"
    control_version="$(sed -n "s/^[[:space:]]*default_version[[:space:]]*=[[:space:]]*'\([^']*\)'.*/\1/p" "$ctl" | head -1)"

    if [ -z "$control_version" ]; then
        echo "artifact: $ctl declares no default_version" >&2
        return 2
    fi
    if [ "$control_version" != "$file_version" ]; then
        echo "artifact: INCOHERENT TRIPLET -- the control file and the install script disagree." >&2
        echo "artifact:   $ctl declares default_version = '$control_version'" >&2
        echo "artifact:   $sql is version '$file_version'" >&2
        echo "artifact: these came from different builds. Rebuild into an empty directory." >&2
        return 2
    fi

    # A coherent filename triplet is not provenance. Require the manifest so stale or substituted
    # bytes cannot look release-verified.
    #
    # The escape hatch is loud, must be asked for by name, and MARKS THE RESULT. A gate that can be
    # silently downgraded is not a gate; one that can be downgraded only by an environment variable
    # that then stamps "UNVERIFIED" through the run is a convenience with a receipt.
    local manifest="$dir/$YB_ART_MANIFEST_NAME"
    YB_ART_VERIFIED="no"
    if [ -f "$manifest" ]; then
        if ! (cd "$dir" && sha256sum --quiet -c "$YB_ART_MANIFEST_NAME") >/dev/null 2>&1; then
            echo "artifact: MANIFEST MISMATCH under $dir -- these are not the files the build produced." >&2
            (cd "$dir" && sha256sum -c "$YB_ART_MANIFEST_NAME") >&2 || true
            return 2
        fi
        YB_ART_VERIFIED="yes"
        echo "artifact: $dir verified against $YB_ART_MANIFEST_NAME (kmoney $control_version)"
    elif [ "${YB_ART_ALLOW_UNVERIFIED:-0}" = "1" ]; then
        echo "artifact: *** UNVERIFIED ARTIFACT ($dir has no $YB_ART_MANIFEST_NAME) ***" >&2
        echo "artifact: *** proceeding only because YB_ART_ALLOW_UNVERIFIED=1. This run is NOT ***" >&2
        echo "artifact: *** release evidence and must not be recorded as any.                 ***" >&2
    else
        echo "artifact: $dir has no $YB_ART_MANIFEST_NAME -- these bytes have no provenance." >&2
        echo "artifact: names and version are coherent, but only the manifest ties these exact" >&2
        echo "artifact: bytes to the build that produced them." >&2
        echo "artifact:" >&2
        echo "artifact:   rebuild (writes the manifest):  just yb-build" >&2
        echo "artifact:   or, for a NON-EVIDENCE run:     YB_ART_ALLOW_UNVERIFIED=1 <command>" >&2
        return 2
    fi

    YB_ART_DIR="$dir"
    YB_ART_SO="$so"
    YB_ART_CTL="$ctl"
    YB_ART_SQL="$sql"
    YB_ART_VERSION="$control_version"
}
