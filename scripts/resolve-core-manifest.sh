#!/usr/bin/env bash
# Resolve the exact kamu-money-core source selected by the lane's Cargo graph.
# Local test mode must select the named-context package; release mode must select
# a registry source. The caller uses the returned manifest to run core's native
# column integration test outside the lane workspace.
set -euo pipefail

mode="${KMONEY_USE_LOCAL_CORE:-1}"
case "$mode" in
    0 | 1) ;;
    *)
        echo "resolve-core-manifest: KMONEY_USE_LOCAL_CORE must be 0 or 1, got '$mode'" >&2
        exit 2
        ;;
esac

read -r manifest source < <(
    cargo metadata --format-version 1 |
        jq -er '
            [.packages[] | select(.name == "kamu-money-core")] |
            if length == 1 then
                [.[0].manifest_path, (.[0].source // "")] | @tsv
            else
                error("expected exactly one kamu-money-core package")
            end
        '
)

case "$mode" in
    1)
        if [ "$manifest" != /opt/kamu-money-core/Cargo.toml ] || [ -n "$source" ]; then
            echo "resolve-core-manifest: local mode selected unexpected source: $manifest ($source)" >&2
            exit 1
        fi
        ;;
    0)
        if [ -z "$source" ] || [[ "$manifest" == /opt/* ]]; then
            echo "resolve-core-manifest: release mode selected a local source: $manifest" >&2
            exit 1
        fi
        ;;
esac

echo "resolve-core-manifest: mode=$mode, source=${source:-named-context}" >&2
printf '%s\n' "$manifest"
