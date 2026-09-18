#!/usr/bin/env bash
# Fail before compilation if core cannot resolve from the committed registry lock.
set -euo pipefail
manifest="$("$(dirname "${BASH_SOURCE[0]}")/resolve-core-manifest.sh")"
printf 'kamu-money-core: locked crates.io source %s\n' "$manifest"
