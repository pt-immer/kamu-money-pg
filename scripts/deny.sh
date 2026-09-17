#!/usr/bin/env bash
# Run cargo-deny with the lane's unpublished local dependency patched in.
#
# cargo-deny runs its own `cargo fetch` and cannot forward Cargo's command-line `--config`. A
# temporary CARGO_HOME supplies only this patch, leaving the lane manifest and ordinary Cargo
# commands untouched, so omitting CORE_PATCH remains the release-resolution proof.
set -euo pipefail

LANE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
CORE_ROOT="$(cd "$LANE_ROOT/../../crates/money-core" && pwd -P)"

command -v cargo-deny >/dev/null 2>&1 || {
    echo "cargo-deny is required; run 'just setup'" >&2
    exit 1
}

CARGO_HOME_TMP="$(mktemp -d -t kamu-money-pg-deny-XXXXXX)"
trap 'rm -rf "$CARGO_HOME_TMP"' EXIT

printf '[patch.crates-io]\nkamu-money-core = { path = "%s" }\n' "$CORE_ROOT" \
    > "$CARGO_HOME_TMP/config.toml"

cd "$LANE_ROOT"
CARGO_HOME="$CARGO_HOME_TMP" cargo-deny \
    --manifest-path "$LANE_ROOT/Cargo.toml" \
    --config "$LANE_ROOT/deny.toml" \
    check
