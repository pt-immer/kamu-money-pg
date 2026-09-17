#!/usr/bin/env bash
# cargo-pgrx has no --locked option and some subprocesses bypass CARGO.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
"$ROOT/scripts/assert-core-resolution.sh"
export KMONEY_REAL_CARGO
KMONEY_REAL_CARGO="$(command -v cargo)"
export CARGO="$ROOT/scripts/locked/cargo"
export PATH="$ROOT/scripts/locked:$PATH"
exec cargo-pgrx pgrx "$@"
