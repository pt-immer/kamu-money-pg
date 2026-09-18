#!/usr/bin/env bash
# Resolve a YugabyteDB image tag to an immutable reference, check it against the pinned digest,
# and print it on stdout. Everything else goes to stderr because callers consume this as
# `YB_REF="$(yb-image.sh ...)"`.
#
# Native artifacts must be compiled and tested against one image identity. A digest provides
# run-local stability; YB-PINNED.txt records which digest was validated with the pgrx fork.
# Unpinned images and drifted pins both fail closed, with separate explicit overrides:
#
#   Usage: yb-image.sh [tag]                 -> prints e.g. yugabytedb/yugabyte@sha256:...
#     YB_ALLOW_DRIFT=1     the tag IS pinned but has moved off the pinned digest -> warn, proceed
#     YB_ALLOW_UNPINNED=1  the tag has NO entry in YB-PINNED.txt at all          -> warn, proceed
#     YB_PULL=1            re-resolve from the REGISTRY instead of trusting the local cache
#     YB_PINFILE=<path>    use a different pin file (the self-test drives a fixture through it)
#
# See RUNBOOK.md for the adoption procedure. Separate overrides prevent approval of one condition
# from approving the other.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TAG="${1:-yugabytedb/yugabyte:2025.2.5.1-b1}"
PINFILE="${YB_PINFILE:-$HERE/YB-PINNED.txt}"

# Ordinary runs ask whether the local image matches the pin. `YB_PULL=1` separately re-resolves
# the tag from the registry.
if [ "${YB_PULL:-0}" = "1" ]; then
    echo "yb-image: pulling $TAG to re-resolve it from the registry" >&2
    docker pull -q "$TAG" >/dev/null
elif ! docker image inspect "$TAG" >/dev/null 2>&1; then
    # Absent locally: there is no cache to trust, so this pull is not a registry question answered
    # from stale data -- it is the only way to have the image at all.
    echo "yb-image: $TAG is not present locally; pulling it once" >&2
    docker pull -q "$TAG" >/dev/null
else
    echo "yb-image: using the LOCAL $TAG (YB_PULL=1 re-resolves it from the registry)" >&2
fi

# RepoDigests is the registry-side immutable name, which is what a rebuild elsewhere can also
# resolve. Prefer it so the recorded identity is meaningful off this machine.
DIGEST="$(docker image inspect --format '{{ index .RepoDigests 0 }}' "$TAG" 2>/dev/null || true)"

if [ -z "$DIGEST" ] || [ "$DIGEST" = "<no value>" ]; then
    # A locally built/imported image has no RepoDigest. The image ID is equally immutable but
    # local-only, so say so on stderr rather than silently falling back to the mutable tag --
    # a reader of the evidence needs to know which kind of identity they are looking at.
    DIGEST="$(docker image inspect --format '{{ .Id }}' "$TAG")"
    echo "yb-image: $TAG has no RepoDigest (local image); using image ID $DIGEST" >&2
fi

# --- the pin check -----------------------------------------------------------------------------
# `if`, never `[ ... ] && printf`: under `set -e` a false test makes the whole && chain return 1,
# which would abort this function partway through the message it exists to print.
refuse() {
    local why="$1" validated="$2" advice="$3"
    {
        printf 'yb-image: REFUSING -- %s\n\n' "$why"
        printf '  tag        %s\n' "$TAG"
        printf '  now        %s\n' "$DIGEST"
        if [ -n "$validated" ]; then
            printf '  validated  %s\n' "$validated"
        fi
        printf '\n%s\n\n' "$advice"
        printf 'The procedure is written down in kamu-money-pg/yb/RUNBOOK.md.\n'
    } >&2
    exit 1
}

if [ ! -f "$PINFILE" ]; then
    if [ "${YB_ALLOW_UNPINNED:-0}" = "1" ]; then
        echo "yb-image: NO PIN FILE, ALLOWED (YB_ALLOW_UNPINNED=1). $PINFILE does not exist," >&2
        echo "yb-image:   so nothing here records what was validated. See RUNBOOK.md, 'Adopt a YugabyteDB image'." >&2
        echo "$DIGEST"
        exit 0
    fi
    refuse "there is no pin file at all." "" \
"$PINFILE does not exist, so nothing in this checkout records which YugabyteDB image the pgrx
fork was validated against. Restore it, or set YB_ALLOW_UNPINNED=1 if you are deliberately
bootstrapping a new one."
fi

PINNED="$(grep -v '^[[:space:]]*#' "$PINFILE" | grep -F "$TAG	" | head -1 | cut -f2 || true)"

if [ -z "$PINNED" ]; then
    if [ "${YB_ALLOW_UNPINNED:-0}" = "1" ]; then
        echo "yb-image: UNPINNED TAG ALLOWED (YB_ALLOW_UNPINNED=1). $TAG has no entry in" >&2
        echo "yb-image:   $PINFILE -- nothing has validated the adaptation against it." >&2
        echo "yb-image: follow RUNBOOK.md, 'Adopt a YugabyteDB image', before this run counts as evidence." >&2
    else
        refuse "the YugabyteDB tag is not recorded in the pin file." "" \
"Nothing has validated the pgrx fork against this image. An unvalidated image can COMPILE and
still be the wrong adaptation, which is the failure this pin exists to catch -- so an unknown
tag is refused for the same reason a moved one is.

To adopt it deliberately:  YB_ALLOW_UNPINNED=1 just yb-ab $TAG"
    fi
elif [ "$PINNED" != "$DIGEST" ]; then
    if [ "${YB_ALLOW_DRIFT:-0}" = "1" ]; then
        echo "yb-image: DRIFT ALLOWED (YB_ALLOW_DRIFT=1). $TAG now resolves to" >&2
        echo "yb-image:   $DIGEST" >&2
        echo "yb-image: but the adaptation was validated against" >&2
        echo "yb-image:   $PINNED" >&2
        echo "yb-image: follow yb/RUNBOOK.md before recording a new pin." >&2
    else
        refuse "the YugabyteDB tag has moved off the validated digest." "$PINNED" \
"The adaptations are facts about YugabyteDB's headers, and one that no longer matches can still
COMPILE -- it is then silently the wrong adaptation. So a new image is adopted deliberately,
never by a docker pull.

To run against the new image without recording it yet:  YB_ALLOW_DRIFT=1 just yb-ab $TAG"
    fi
else
    echo "yb-image: $TAG is at the validated digest" >&2
fi

echo "$DIGEST"
