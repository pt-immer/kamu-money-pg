#!/usr/bin/env bash
# Execute the pgrx-free artifact authority. This adapter exports no paths or verification flags:
# every evidence-consuming operation remains inside the Rust process that verified the owned bytes.
set -euo pipefail
cd "$(dirname "$0")/../.."
exec cargo run --quiet --locked -p kamu-money-pg-artifact -- "$@"
