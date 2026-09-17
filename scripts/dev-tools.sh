#!/usr/bin/env bash
# Provision repository-local fallback tools; keep a satisfying host tool first.
set -euo pipefail
cd "$(dirname "$0")/.."
mode="${1:-doctor}"
case "$mode" in setup|doctor) ;; *) echo "usage: dev-tools.sh setup|doctor" >&2; exit 2 ;; esac
command -v jq >/dev/null || { echo "jq is required to read .config/dev-tools.json" >&2; exit 1; }
export PATH="$PATH:$PWD/.tools/bin:$PWD/node_modules/.bin"
rc=0
entries=$(jq -er '.cargo_tools | to_entries[] | [.key, (.value.binary // .key), .value.version, (.value | has("exact"))] | @tsv' .config/dev-tools.json)
while IFS=$'\t' read -r name binary version exact; do
    have=""
    if command -v "$binary" >/dev/null; then
        have=$("$binary" --version | head -n 1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1) || true
    fi
    if [[ "$have" == "$version" ]] || { [[ "$exact" == false && -n "$have" ]] && [[ $(printf '%s\n' "$version" "$have" | sort -V | head -n 1) == "$version" ]]; }; then
        echo "✓ $name $have"
    elif [[ "$mode" == setup ]]; then
        # Never shadow a host binary: ask for its upgrade instead of installing an unused copy.
        if command -v "$binary" >/dev/null; then
            echo "✗ $name: host $have does not satisfy $version; upgrade that installation" >&2
            rc=1
        elif cargo install --locked --root "$PWD/.tools" --version "=$version" "$name"; then
            echo "✓ $name $version installed"
        else
            rc=1
        fi
    else
        echo "✗ $name: need $version, found ${have:-missing}; run just setup" >&2
        rc=1
    fi
done <<< "$entries"
if [[ "$mode" == setup ]]; then
    npm ci || rc=1
fi
for tool in shellcheck markdownlint-cli2; do
    want=$(jq -er --arg tool "$tool" '[.system_tools, .node_tools] | map(.[$tool]) | map(select(. != null)) | .[0].version' .config/dev-tools.json)
    have=$("$tool" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1) || have=""
    if [[ "$have" == "$want" ]]; then echo "✓ $tool $have"; else
        echo "✗ $tool: need $want, found ${have:-missing}" >&2; rc=1
    fi
done
exit "$rc"
