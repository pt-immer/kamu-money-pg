#!/usr/bin/env bash
# Warn when the SELECTED buildx builder cannot export a cache, and refuse only when that is
# certain.
#
#   bash scripts/require-cache-exporter.sh <caller>
#
# `docker buildx build` uses whichever builder is currently selected, not a container one, and only
# the docker-container driver can export a cache. Naming `buildx` in the command says nothing about
# that, so on a machine whose `default` builder is the stock docker driver -- every machine where
# no other builder has been created -- `--cache-to type=local` aborts with a driver error after the
# context has already been sent. This turns that into a diagnostic with the command that fixes it.
#
# AN INCONCLUSIVE PROBE PROCEEDS. `docker buildx inspect` can fail for reasons that say nothing
# about the driver -- a builder created but not yet bootstrapped, a daemon that is slow to answer --
# and a check that cannot determine the answer must not be the thing that fails the build. It says
# what it saw and gets out of the way; if the driver really cannot export, the build itself fails a
# few seconds later with BuildKit's own precise error, which is where this stood before.
set -euo pipefail

CALLER="${1:-cache export}"

# NOT `DRIVER="$(docker ... | awk ...)"`. Under `set -e` with `pipefail` a failing probe aborts the
# script AT THE ASSIGNMENT, so every diagnostic below is unreachable and the caller sees a bare
# non-zero exit -- which is precisely how this script broke a green CI job once.
set +e
INSPECT="$(docker buildx inspect 2>&1)"
STATUS=$?
set -e

if [ "$STATUS" -ne 0 ]; then
    echo "$CALLER: could not inspect the selected buildx builder (exit $STATUS), so whether it can" >&2
    echo "$CALLER: export a cache is unknown. Proceeding; BuildKit will say so if it cannot." >&2
    printf '%s\n' "$INSPECT" | sed "s/^/$CALLER: /" >&2
    exit 0
fi

DRIVER="$(printf '%s\n' "$INSPECT" | awk -F': *' '/^Driver:/ { print $2; exit }')"

case "$DRIVER" in
    docker-container | kubernetes | remote)
        exit 0
        ;;
    "")
        echo "$CALLER: the buildx inspect output names no driver, so this check cannot decide." >&2
        echo "$CALLER: Proceeding; BuildKit will refuse the export if the builder cannot do it." >&2
        exit 0
        ;;
esac

echo "$CALLER: KMONEY_BUILD_CACHE_DIR is set, so this build exports a BuildKit cache, but the" >&2
echo "$CALLER: selected buildx builder uses the '$DRIVER' driver, which cannot export one." >&2
echo "$CALLER:" >&2
echo "$CALLER:   docker buildx create --name kmoney --driver docker-container --use" >&2
echo "$CALLER:" >&2
echo "$CALLER: or leave KMONEY_BUILD_CACHE_DIR unset, which is the ordinary local arrangement --" >&2
echo "$CALLER: the daemon already holds these layers." >&2
exit 2
