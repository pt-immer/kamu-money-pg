#!/usr/bin/env bash
# Cargo proxy for tools that spawn Cargo without forwarding command-line config.
set -euo pipefail

: "${KMONEY_REAL_CARGO:?caller must provide the real Cargo executable}"
: "${KMONEY_CORE_PATH:?caller must provide the kamu-money-core path}"

exec "$KMONEY_REAL_CARGO" \
    --config "patch.crates-io.kamu-money-core.path=\"$KMONEY_CORE_PATH\"" \
    "$@"
