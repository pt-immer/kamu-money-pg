#!/usr/bin/env bash
# Resolve the exact registry core selected by the committed Cargo.lock.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
manifest="$(cargo metadata --locked --format-version 1 --manifest-path "$ROOT/Cargo.toml" |
    jq -er '
        [.packages[] | select(.name == "kamu-money-core")] |
        if length != 1 then error("expected exactly one kamu-money-core package")
        elif .[0].source != "registry+https://github.com/rust-lang/crates.io-index"
        then error("kamu-money-core must resolve from crates.io")
        else .[0].manifest_path end
    ')"
for required in Cargo.toml tests/pg_native_column.rs tests/yugabyte_roundtrip.rs; do
    test -f "${manifest%/*}/$required" || {
        echo "resolve-core-manifest: published core package is missing $required" >&2
        exit 1
    }
done
printf '%s\n' "$manifest"
