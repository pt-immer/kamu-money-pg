#!/usr/bin/env bash
# Run kamu-money-core's postgres-types/sqlx tests against a native kmoney column. The pgrx image
# owns PostgreSQL and the test process; the trap owns container cleanup.
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root
# shellcheck source=scripts/docker-core-context.sh
source ./scripts/docker-core-context.sh

PG_MAJOR="${1:-18}"
RUN_ID="$$-$(date +%s)"
LABEL="kamu-money-pg.driver=${RUN_ID}"
NAME="kamu-money-pg-driver-${RUN_ID}"
IIDFILE="$(mktemp)"

cleanup() {
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    # Cleanup is scoped to this run on the shared daemon.
    for id in $(docker ps -aq --filter "label=${LABEL}" 2>/dev/null || true); do
        docker rm -f "$id" >/dev/null 2>&1 || true
    done
    [ -n "${IIDFILE:-}" ] && rm -f "$IIDFILE" 2>/dev/null
    return 0
}
trap cleanup EXIT INT TERM HUP

echo "=== building the kamu-money-pg image (PG${PG_MAJOR}) ==="
# Capture and run the immutable image ID; use a tag separate from the benchmark matrix.
docker build "${KMONEY_CORE_DOCKER_ARGS[@]}" \
    -f kamu-money-pg/Dockerfile --build-arg "PG_MAJOR=${PG_MAJOR}" \
    --label "${LABEL}" --iidfile "${IIDFILE}" -t "kamu-money-pg-driver:pg${PG_MAJOR}" .
IMAGE_ID="$(cat "${IIDFILE}")"
rm -f "${IIDFILE}"; IIDFILE=""
echo "=== running the native-column driver test in ${IMAGE_ID} ==="

# The database remains on container loopback.
docker run --rm --name "$NAME" --label "${LABEL}" \
    -e "PG_MAJOR=${PG_MAJOR}" "${IMAGE_ID}" bash -euxo pipefail -c '
    PGCFG="/usr/lib/postgresql/${PG_MAJOR}/bin/pg_config"

    # Install the extension into the PostgreSQL this image already carries.
    cargo pgrx install -p kamu-money-pg --no-default-features \
        --features "pg${PG_MAJOR}" -c "$PGCFG"

    # pgrx manages its own instance; its port convention is 28800 + major.
    cargo pgrx start "pg${PG_MAJOR}"
    PORT=$((28800 + PG_MAJOR))

    export MONEY_PG_NATIVE_URL="postgres://$(id -un)@127.0.0.1:${PORT}/postgres"
    echo "native driver URL: ${MONEY_PG_NATIVE_URL}"

    # Serialize CREATE EXTENSION against the shared database. Assert count and skip text because
    # the Rust tests intentionally skip when MONEY_PG_NATIVE_URL is absent.
    CORE_MANIFEST="$(./scripts/resolve-core-manifest.sh)"
    cargo test --manifest-path "$CORE_MANIFEST" \
        --features postgres,sqlx --test pg_native_column \
        -- --nocapture --test-threads=1 2>&1 | tee /tmp/native-driver.out
    if ! grep -q "4 passed" /tmp/native-driver.out; then
        echo "native-driver-test: FAILED -- expected 4 passing tests; the suite changed size" >&2
        exit 1
    fi
    if grep -q "skipping:" /tmp/native-driver.out; then
        echo "native-driver-test: FAILED -- tests SKIPPED, so nothing was proven" >&2
        exit 1
    fi
'
echo "native-driver-test: OK (PG${PG_MAJOR})"
