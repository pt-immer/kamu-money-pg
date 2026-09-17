#!/usr/bin/env bash
# Build and test kamu-money-pg against every supported PostgreSQL major, in containers.
#
#   ./kamu-money-pg/test-matrix.sh            # PG15..latest supported
#   ./kamu-money-pg/test-matrix.sh 17 18      # a subset
#
# Builds capture immutable image IDs because tags are mutable on the shared daemon.
set -euo pipefail

# Tested support spans PostgreSQL 15-18.
DEFAULT_MAJORS=(15 16 17 18)
MAJORS=("${@:-${DEFAULT_MAJORS[@]}}")

cd "$(dirname "$0")/.."
# shellcheck source=scripts/docker-core-context.sh
source ./scripts/docker-core-context.sh

# Include random entropy because PID namespaces can repeat on a shared daemon.
REVISION="$(git rev-parse --short HEAD 2>/dev/null || echo nogit)"

# Keep the image label as the bare revision; record dirty state only in output.
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    TREE_STATE=", dirty tree built beyond ${REVISION}"
else
    TREE_STATE=""
fi
ENTROPY="$(od -An -N4 -tx4 /dev/urandom | tr -d ' \n')"
RUN_ID="${REVISION}-$$-${ENTROPY}"
LABEL="kamu-money-pg.run=${RUN_ID}"
IIDFILE=""

# Remove only containers carrying this run's label, including on interruption.
cleanup() {
  local ids
  ids=$(docker ps -aq --filter "label=${LABEL}" 2>/dev/null || true)
  if [ -n "$ids" ]; then
    # shellcheck disable=SC2086 # word splitting is the point; ids is a list
    docker rm -f $ids >/dev/null 2>&1 || true
  fi
  [ -n "$IIDFILE" ] && rm -f "$IIDFILE" 2>/dev/null
  return 0
}
trap cleanup EXIT INT TERM HUP

failed=()

# One shared implementation for sequential and parallel execution.
one_major() {
  local pg="$1"
  echo "=============================== PG${pg} ==============================="

  # A portable layer cache, for a builder that has no daemon-side one.
  #
  # Locally this stays unset and the daemon's own layer cache does the work. In CI every job
  # starts against an empty daemon, so without it the dependency layer is rebuilt from nothing
  # every run and moving that compile into a layer buys nothing. Scoped per major because a
  # pg15 dependency layer is not a pg16 one: pgrx-pg-sys generates different bindings for each.
  #
  # Naming `buildx` explicitly, and `--load` with it. Exporting a cache needs the
  # docker-container driver, which the default `docker` driver is not, and which does not put
  # the built image in the daemon by itself -- and this function has to `docker run` it below.
  # Depending on which builder a bare `docker build` happens to route to would make the export
  # silently do nothing on some hosts.
  # Each form carries the normalized core context on its own line, rather than composing the
  # command in one place and the context in another: `docker_builds_share_the_normalized_core_package`
  # reads these lines individually, and a build that resolves kamu-money-core differently from
  # its siblings is exactly what it exists to catch.
  local -a build_cmd
  if [ -n "${KMONEY_BUILD_CACHE_DIR:-}" ]; then
    bash ./scripts/require-cache-exporter.sh test-matrix
    mkdir -p "${KMONEY_BUILD_CACHE_DIR}/pg${pg}"
    build_cmd=(docker buildx build --load "${KMONEY_CORE_DOCKER_ARGS[@]}"
      --cache-from "type=local,src=${KMONEY_BUILD_CACHE_DIR}/pg${pg}"
      --cache-to "type=local,dest=${KMONEY_BUILD_CACHE_DIR}/pg${pg},mode=max")
  else
    build_cmd=(docker build "${KMONEY_CORE_DOCKER_ARGS[@]}")
  fi

  local iidfile image_id t0 t_image t_test
  iidfile="$(mktemp)"
  t0=$SECONDS
  # --iidfile records the image ID this build actually produced. The -t tag is a convenience
  # for a human; it is deliberately not what gets run below.
  if ! "${build_cmd[@]}" \
        -f kamu-money-pg/Dockerfile --build-arg "PG_MAJOR=${pg}" \
        --label "${LABEL}" --label "kamu-money-pg.revision=${REVISION}" \
        --iidfile "${iidfile}" -t "kamu-money-pg:pg${pg}" . ; then
    echo "PG${pg}: BUILD FAILED"; rm -f "${iidfile}"; return 1
  fi
  image_id="$(cat "${iidfile}")"
  rm -f "${iidfile}"
  t_image=$((SECONDS - t0))
  echo "PG${pg}: testing image ${image_id}"

  # Cargo caches persist across runs in named volumes: the compile happens at
  # RUN time (the image CMD is `cargo pgrx test`), so without these every run
  # rebuilds pgrx and all dependencies into a fresh /work/target. Cargo's own
  # fingerprinting decides what is reusable, so this trades no correctness --
  # only the re-proving of unchanged compilation. The target volume is
  # per-major (fingerprints differ per pg feature); the registry volume is
  # shared (cargo takes its own locks). KMONEY_TEST_CACHE=0 restores the
  # from-scratch behaviour.
  local cache_args=()
  if [ "${KMONEY_TEST_CACHE:-1}" != "0" ]; then
    cache_args=(-v "kmoney-cargo-registry:/home/pgrx/.cargo/registry"
                -v "kmoney-cargo-target-pg${pg}:/work/target")
  fi

  # Run the ID, not the tag. Between the build above and this line, another runner on this
  # shared daemon may have moved `kamu-money-pg:pg${pg}` to its own revision.
  t0=$SECONDS
  if ! docker run --rm --label "${LABEL}" "${cache_args[@]}" \
        --name "kamu-money-pg-${RUN_ID}-pg${pg}" "${image_id}"; then
    echo "PG${pg}: TESTS FAILED"; return 1
  fi
  t_test=$((SECONDS - t0))
  echo "PG${pg}: OK (image ${t_image}s, compile+test ${t_test}s)"
}

# Optional parallelism is bounded by the operator; buffered logs replay in major order.
MATRIX_JOBS="${MATRIX_JOBS:-1}"

# Validate before numeric comparison because a failed conditional test bypasses `set -e`.
# just-anti-example: `just test-pg "15 16" jobs=4` passes a nonnumeric positional value.
case "$MATRIX_JOBS" in
  ''|*[!0-9]*)
    echo "test-matrix: MATRIX_JOBS must be a positive integer, got '$MATRIX_JOBS'" >&2
    echo "test-matrix: via just, arguments are POSITIONAL -- 'just test-pg \"15 16\" 4'." >&2
    exit 2 ;;
esac
[ "$MATRIX_JOBS" -ge 1 ] || { echo "test-matrix: MATRIX_JOBS must be >= 1" >&2; exit 2; }

if [ "$MATRIX_JOBS" -le 1 ]; then
  for pg in "${MAJORS[@]}"; do
    one_major "$pg" || failed+=("pg${pg}")
  done
else
  echo "matrix: running ${#MAJORS[@]} majors with up to ${MATRIX_JOBS} concurrent (MATRIX_JOBS)"
  LOGDIR="$(mktemp -d)"
  declare -A PID_OF=()
  for pg in "${MAJORS[@]}"; do
    while [ "$(jobs -rp | wc -l)" -ge "$MATRIX_JOBS" ]; do wait -n || true; done
    one_major "$pg" > "${LOGDIR}/pg${pg}.log" 2>&1 &
    PID_OF[$pg]=$!
  done
  for pg in "${MAJORS[@]}"; do
    wait "${PID_OF[$pg]}" || failed+=("pg${pg}")
    cat "${LOGDIR}/pg${pg}.log"
  done
  rm -rf "$LOGDIR"
fi

echo
if [ ${#failed[@]} -eq 0 ]; then
  echo "matrix green: ${MAJORS[*]} (revision ${REVISION}${TREE_STATE})"
else
  # Report every failed major.
  echo "matrix FAILED: ${failed[*]} (revision ${REVISION}${TREE_STATE})"
  exit 1
fi
