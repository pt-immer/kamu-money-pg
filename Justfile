# Excluded PostgreSQL extension workspace. Enter through `just pg <recipe>` from
# the repository root. Root policy owns shell lint and scrub for this whole tree.
set shell := ["bash", "-uc"]

PG_MAJORS := "15 16 17 18"

# Keep the nested quotes: Cargo must parse the path as TOML. For nextest, pass
# this after the subcommand so child metadata invocations inherit it.
CORE_PATCH := "--config 'patch.crates-io.kamu-money-core.path=\"../../crates/money-core\"'"

[doc("List extension-lane recipes.")]
default:
    @just --list --unsorted

# Environment
[doc("Install the toolchain pieces the gates need. Idempotent.")]
setup:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0

    if ! command -v rustup >/dev/null 2>&1; then
        echo "setup: rustup not found -- this machine's rust came from somewhere else."
        echo "setup: install these components however that toolchain does it: rustfmt, clippy, rust-src"
        rc=1
    else
        for c in rustfmt clippy; do
            if rustup component add "$c" >/dev/null 2>&1; then
                echo "setup: rustup component $c ok"
            else
                echo "setup: FAILED to add rustup component $c" >&2
                rc=1
            fi
        done

        if cargo +nightly miri --version >/dev/null 2>&1; then
            echo "setup: nightly Miri already present"
        elif rustup component add miri --toolchain nightly >/dev/null 2>&1; then
            echo "setup: nightly Miri ok"
        else
            echo "setup: FAILED to add Miri to the nightly toolchain" >&2
            echo "setup: install nightly first with: rustup toolchain install nightly --profile minimal" >&2
            rc=1
        fi
    fi

    want_pgrx=$(grep -m1 '^pgrx = ' kamu-money-pg/Cargo.toml | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
    if [ -z "$want_pgrx" ]; then
        echo "setup: could not read the pinned pgrx version from kamu-money-pg/Cargo.toml" >&2
        rc=1
    elif command -v cargo-pgrx >/dev/null 2>&1 && \
         [ "$(cargo pgrx --version | awk '{print $2}')" = "$want_pgrx" ]; then
        echo "setup: cargo-pgrx $want_pgrx already matches the pin"
    else
        echo "setup: installing cargo-pgrx $want_pgrx (this compiles; it takes a few minutes)"
        if cargo install --locked cargo-pgrx --version "$want_pgrx"; then
            echo "setup: cargo-pgrx $want_pgrx ok"
        else
            echo "setup: FAILED to install cargo-pgrx $want_pgrx" >&2
            rc=1
        fi
    fi

    if command -v shellcheck >/dev/null 2>&1; then
        echo "setup: shellcheck present"
    else
        id=$(. /etc/os-release 2>/dev/null && echo "${ID:-} ${ID_LIKE:-}")
        case "$id" in
            *arch*)             cmd="sudo pacman -S shellcheck" ;;
            *debian*|*ubuntu*)  cmd="sudo apt-get install shellcheck" ;;
            *fedora*|*rhel*)    cmd="sudo dnf install ShellCheck" ;;
            *)                  cmd="install 'shellcheck' with this system's package manager" ;;
        esac
        echo "setup: ShellCheck is missing; install it with: $cmd"
        rc=1
    fi

    echo
    echo "setup: not done here, and deliberately -- 'just pgrx-init' builds a PostgreSQL against a"
    echo "setup: system pg_config, which is a choice (which major?) and several minutes. Run it if"
    echo "setup: you want 'just check-pg' and the kamu-money-pg clippy leg to work locally."
    echo "setup: now run 'just doctor'."
    exit "$rc"

[doc("Report every extension-lane prerequisite and cleanup warning.")]
[no-exit-message]
doctor:
    #!/usr/bin/env bash
    # No `-e`: every check runs, so one absent tool cannot hide the rest.
    set -uo pipefail

    # Color an interactive terminal only, and never when NO_COLOR is set, so a
    # redirected or captured run stays plain text.
    if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
        B=$'\033[1m'; D=$'\033[2m'; R=$'\033[0m'
        G=$'\033[32m'; Y=$'\033[33m'; X=$'\033[31m'; C=$'\033[36m'
    else
        B=''; D=''; R=''; G=''; Y=''; X=''; C=''
    fi
    W=22
    hard=0
    soft=0
    pass=0
    # `!`, not `•`: the root doctor spends `•` on a tool that passed from
    # outside the repository. A lane warning is not a pass, so it takes its own
    # glyph rather than teaching two meanings for one mark.
    ok()   { printf '  %s✓%s %-*s %s%s%s\n' "$G" "$R" "$W" "$1" "$D" "$2" "$R"; pass=$((pass+1)); }
    warn() { printf '  %s!%s %-*s %s%s%s\n' "$Y" "$R" "$W" "$1" "$Y" "$2" "$R"; soft=$((soft+1)); }
    fail() { printf '  %s✗%s %-*s %s%s%s\n' "$X" "$R" "$W" "$1" "$X" "$2" "$R"; hard=$((hard+1)); }
    sec()  { printf '\n%s%s%s\n' "$B$C" "$1" "$R"; }

    printf '\n%skmoney · doctor%s  %sextension-lane prerequisites%s\n' "$B$C" "$R" "$D" "$R"

    sec "Toolchain"
    if command -v cargo >/dev/null; then
        ok "cargo" "$(cargo --version | cut -d' ' -f2)"
    else
        fail "cargo" "not found — nothing in this lane can build"
    fi
    if command -v rustc >/dev/null; then
        have=$(rustc --version | cut -d' ' -f2)
        want=$(grep -m1 'rust-version' Cargo.toml | tr -d '" ' | cut -d= -f2)
        if [ "$(printf '%s\n%s\n' "$want" "$have" | sort -V | head -1)" = "$want" ]; then
            ok "rustc" "$have  ≥ $want (workspace rust-version)"
        else
            fail "rustc" "$have — below the workspace rust-version $want"
        fi
    else
        fail "rustc" "not found"
    fi
    if cargo fmt --version >/dev/null 2>&1; then
        ok "rustfmt" "present"
    else
        fail "rustfmt" "missing — rustup component add rustfmt"
    fi
    if cargo clippy --version >/dev/null 2>&1; then
        ok "clippy" "present"
    else
        fail "clippy" "missing — rustup component add clippy"
    fi
    if cargo +nightly miri --version >/dev/null 2>&1; then
        ok "nightly Miri" "present"
    else
        fail "nightly Miri" "missing — rustup component add miri --toolchain nightly"
    fi

    sec "Containers"
    if command -v docker >/dev/null; then
        if docker info >/dev/null 2>&1; then
            ok "docker" "daemon reachable"
            n=$(docker ps -q | wc -l)
            ok "shared daemon" "$n container(s) running — never global-prune here"
            all=$(docker ps -aq --filter 'label=kamu-money-pg.revision' | wc -l)
            live=$(docker ps -q --filter 'label=kamu-money-pg.revision' | wc -l)
            leaked=$((all - live))
            if [ "$leaked" -gt 0 ]; then
                warn "test-matrix" "$leaked leaked container(s) — run: just containers"
            elif [ "$live" -gt 0 ]; then
                ok "test-matrix" "no leaked containers ($live running — a matrix is live)"
            else
                ok "test-matrix" "no leaked containers"
            fi
        else
            warn "docker" "installed but the daemon is unreachable — container suites will be skipped"
        fi
    else
        warn "docker" "not found — test-db, test-yb and test-pg cannot run"
    fi

    sec "kamu-money-pg (pgrx)"
    if [ -f ".pgrx/config.toml" ]; then
        ok ".pgrx" "present — check-pg compiles kamu-money-pg without a container"
    else
        warn ".pgrx" "absent — run: just pgrx-init; until then only containers build it"
    fi
    # cargo-pgrx is matched exactly, not as a floor: it is one half of an ABI
    # pairing with the pinned pgrx dependency, not a capability threshold.
    if command -v cargo-pgrx >/dev/null; then
        have_pgrx=$(cargo pgrx --version | awk '{print $2}')
        want_pgrx=$(grep -m1 '^pgrx = ' kamu-money-pg/Cargo.toml | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
        if [ "$have_pgrx" = "$want_pgrx" ]; then
            ok "cargo-pgrx" "$have_pgrx matches the pinned pgrx dependency"
        else
            fail "cargo-pgrx" "$have_pgrx — kamu-money-pg pins pgrx $want_pgrx; they must match"
        fi
    else
        warn "cargo-pgrx" "not installed — pgrx-init and test-pg need it"
    fi

    sec "Hygiene"
    if git rev-parse --git-dir >/dev/null 2>&1; then
        ok "git work tree" "inside one"
        if grep -qE '^(repository|license|publish) = ' kamu-money-pg/Cargo.toml; then
            warn "manifest fields" "kamu-money-pg hard-codes repository/license/publish — a literal overrides [workspace.package]"
        else
            ok "manifest fields" "inherited from the lane root"
        fi
        declared="$(grep -m1 '^repository = ' Cargo.toml 2>/dev/null | cut -d'"' -f2 || true)"
        actual="$(git remote get-url "$(git remote | head -1)" 2>/dev/null || echo '')"
        if [ -z "$declared" ]; then
            warn "repository field" "the lane root declares none"
        else
            case "$actual" in
                *"${declared#https://github.com/}"*) ok "repository field" "matches the git remote" ;;
                # The remote URL is not echoed: it can name a host, and this
                # report is pasted into issues. `git remote -v` shows it.
                *) warn "repository field" "declared '$declared' but the remote differs" ;;
            esac
        fi
    else
        fail "git work tree" "not inside one"
    fi
    leaked_certs=$(git status --porcelain --untracked-files=all 2>/dev/null | grep -cE '\.(crt|pem|key)$')
    if [ "$leaked_certs" -gt 0 ]; then
        fail "certificates" "$leaked_certs untracked, unignored key or cert file(s) — fix .gitignore before any commit:"
        # Indent to the detail column the row helpers use: two spaces, the
        # marker, a space, the label padded to $W, then one space.
        git status --porcelain --untracked-files=all | grep -E '\.(crt|pem|key)$' | sed "s/^/$(printf '%*s' $((W + 5)) '')/"
    else
        ok "certificates" "none untracked"
    fi

    printf '\n'
    if [ "$hard" -gt 0 ]; then
        printf '%s%s✗ %d failed%s   %s✓ %d ok%s   %s! %d warning(s)%s\n' \
            "$B" "$X" "$hard" "$R" "$G" "$pass" "$R" "$Y" "$soft" "$R"
        exit 1
    fi
    # "healthy", not "all good": warnings do not fail the lane, but a headline
    # that contradicts the count beside it teaches the reader to skip both.
    printf '%s%s✓ healthy%s   %s✓ %d ok%s   %s! %d warning(s)%s\n' \
        "$B" "$G" "$R" "$G" "$pass" "$R" "$Y" "$soft" "$R"


# Build and static checks
[doc("Format the extension workspace.")]
fmt:
    cargo fmt --all

[doc("Verify formatting without changing anything.")]
fmt-check:
    cargo fmt --all --check


[doc("Clippy the extension at the pedantry its crate root denies, pinned to one PG major.")]
lint:
    cargo clippy {{ CORE_PATCH }} -p kamu-money-pg --no-default-features --features pg18 --all-targets -- -D warnings

[doc("Audit the lane lockfile, allowing only the pinned public pgrx fork.")]
deny:
    ./scripts/deny.sh

[doc("Populate the in-repo PGRX_HOME from the host pg_config.")]
pgrx-init pg_config="/usr/bin/pg_config":
    #!/usr/bin/env bash
    set -euo pipefail
    major=$("{{ pg_config }}" --version | grep -oE '[0-9]+' | head -1)
    echo "initialising .pgrx for PG${major} from {{ pg_config }}"
    cargo pgrx init "--pg${major}" "{{ pg_config }}"
    if [ ! -e .pgrx ]; then
        ln -sfn "${PGRX_HOME:-$HOME/.pgrx}" .pgrx
        echo "linked .pgrx -> ${PGRX_HOME:-$HOME/.pgrx} (cargo pgrx init ignores the forced [env] path)"
    fi
    [ -f .pgrx/config.toml ] || { echo "pgrx-init: .pgrx/config.toml still missing" >&2; exit 1; }
    echo "pgrx-init: ready -- 'just check-pg' and the kamu-money-pg clippy leg can now run"

[doc("Compile-check kamu-money-pg locally against one major (no container, no tests).")]
check-pg pg="18":
    cargo check {{ CORE_PATCH }} -p kamu-money-pg --no-default-features --features pg{{ pg }} --all-targets

[doc("Fingerprint normalized generated SQL, optionally checking an expected hash.")]
schema-hash pg="18" expect="" features="":
    ./kamu-money-pg/schema-hash.sh {{ pg }} "{{ expect }}" "{{ features }}"

[doc("Run pgrx-free repository guards and safe-payload tests.")]
test-hygiene:
    cargo nextest run {{ CORE_PATCH }} -p kamu-money-pg-hygiene
    cargo test {{ CORE_PATCH }} -p kamu-money-pg-hygiene --doc

[doc("Run Miri over the exact pgrx-free payload codec.")]
miri-payload:
    cargo +nightly miri test {{ CORE_PATCH }} -p kamu-money-pg-hygiene --test payload_miri

# rustdoc reads only what it is told to compile and told to keep, and this crate
# defaults both to almost nothing. Every `#[pg_extern]` and `#[pg_operator]` is a
# private `fn` and `ffi` and `safe` are private modules, because the published
# surface is SQL rather than Rust, so without `--document-private-items` the input
# set is the generated `pub struct` per currency. `pg_test` and `boundary-probe`
# gate a third of the crate's prose, and `pg18` implies neither.
#
# The deny is written here, on the invocation, rather than as `build.rustdocflags`
# in `.cargo/config.toml`: an ambient `RUSTDOCFLAGS` REPLACES a configured value
# outright, and this repository already exports the sibling `RUSTFLAGS` at
# workflow level. Assigned here it overrides an inherited one instead of being
# overridden by it. The space matters too -- cargo splits this variable on
# whitespace, while a one-element `["-D warnings"]` array reaches rustdoc as a
# single argv token it rejects, warning about the flag and about nothing else.
#
# `hygiene/tests/doc_gate.rs` proves all three settings by planting a broken
# link in each region and requiring this recipe to report every one. A test that
# read the settings instead was twice wrong about exactly the spellings above.
#
# pg18 alone. `pgrx-init` registers the single major its `pg_config` names, and
# both lane CI jobs point it at PostgreSQL 18, so any other major fails in the
# `pgrx-pg-sys` build script rather than in rustdoc.
[doc("Build the extension's API docs, failing on a broken intra-doc link.")]
doc-pg:
    RUSTDOCFLAGS='-D warnings' cargo doc {{ CORE_PATCH }} -p kamu-money-pg --no-default-features --features pg18,pg_test,boundary-probe --no-deps --document-private-items

# Database and artifact tests
[doc("The text adapter against a live YugabyteDB. The suite is in the main workspace; the image identity is resolved here.")]
test-yb tag="":
    #!/usr/bin/env bash
    set -euo pipefail
    IMAGE="${KMONEY_YB_IMAGE:-$(./kamu-money-pg/yb/yb-image.sh {{ tag }})}"
    echo "test-yb: text adapter against $IMAGE"
    KMONEY_YB_IMAGE="$IMAGE" \
        cargo test --manifest-path ../../Cargo.toml \
            -p kamu-money-core --features postgres --test yugabyte_roundtrip -- --ignored --nocapture

[doc("The pgrx extension suite, once per supported PostgreSQL major, each in a container.")]
test-pg majors=PG_MAJORS jobs="1":
    MATRIX_JOBS={{ jobs }} ./kamu-money-pg/test-matrix.sh {{ majors }}

[doc("Reproduce the unadapted YugabyteDB build blockers.")]
yb-probe yb-image="" builder-image="":
    ./kamu-money-pg/yb-compat-probe.sh "{{ yb-image }}" "{{ builder-image }}"
[doc("Build the deployable node image with kmoney baked in.")]
yb-node-image tag="":
    #!/usr/bin/env bash
    set -euo pipefail
    YB_REF="$(./kamu-money-pg/yb/yb-image.sh {{ tag }})"
    IMAGE_ID="$(./kamu-money-pg/yb/node-image.sh "$YB_REF")"
    echo
    echo "node image built"
    echo "  base      $YB_REF"
    echo "  image id  $IMAGE_ID"
    echo
    echo "Every node -- primary and read replica, RF3 and RF5 -- runs this one image; nothing is"
    echo "ever installed onto a running node."
    echo
    echo "This local image ID is not a registry digest. Record the immutable registry digest"
    echo "after the platform publishes it; 'just gate-pg-release' certifies bytes, not distribution."

[doc("Build the kamu-money-pg artifact against YugabyteDB's PG15 fork (pgrx fork + yb-pg15).")]
yb-build tag="":
    #!/usr/bin/env bash
    set -euo pipefail
    source ./kamu-money-pg/yb/workspace-lock.sh
    workspace_lock "yb-build" || exit 1
    RUN_ROOT="${KMONEY_RUN_ROOT:-kamu-money-pg/yb/out}"
    YB_REF="$(./kamu-money-pg/yb/yb-image.sh {{ tag }})"
    echo "yb: image identity $YB_REF"
    source ./scripts/docker-core-context.sh
    # CI sets KMONEY_BUILD_CACHE_DIR; locally it stays unset, because the daemon already holds
    # these layers. Two invocations rather than one: `mode=max` over the whole graph would also
    # export the package step's multi-gigabyte target/ diff, on every source change -- an upload
    # paid every run and restored by nothing. Scoping the export to the `deps` target bounds it to
    # the layers that are actually reused, and the second build reuses the first's in-builder cache.
    #
    # `buildx` is named explicitly, because exporting a cache needs the docker-container driver and
    # the default `docker` driver is not it. Depending on which builder a bare `docker build`
    # happens to route to would make the export silently do nothing on some hosts.
    #
    # Each form carries the normalized core context on its own line rather than composing the
    # command in one place and the context in another: docker_builds_share_the_normalized_core_package
    # reads these lines individually, and a build that resolves kamu-money-core differently from its
    # siblings is what it exists to catch.
    if [ -n "${KMONEY_BUILD_CACHE_DIR:-}" ]; then
        bash ./scripts/require-cache-exporter.sh yb-build
        mkdir -p "${KMONEY_BUILD_CACHE_DIR}/yb"
        docker buildx build "${KMONEY_CORE_DOCKER_ARGS[@]}" \
            -f kamu-money-pg/yb/Dockerfile --target deps --output type=cacheonly \
            --build-arg YB_IMAGE="$YB_REF" \
            --build-arg KMONEY_CACHE_ID="${KMONEY_CACHE_ID:-shared}" \
            --cache-from "type=local,src=${KMONEY_BUILD_CACHE_DIR}/yb" \
            --cache-to "type=local,dest=${KMONEY_BUILD_CACHE_DIR}/yb,mode=max" .
        docker buildx build "${KMONEY_CORE_DOCKER_ARGS[@]}" \
            -f kamu-money-pg/yb/Dockerfile --target artifact \
            --build-arg YB_IMAGE="$YB_REF" \
            --build-arg KMONEY_CACHE_ID="${KMONEY_CACHE_ID:-shared}" \
            --cache-from "type=local,src=${KMONEY_BUILD_CACHE_DIR}/yb" -o "$RUN_ROOT" .
    else
        docker build "${KMONEY_CORE_DOCKER_ARGS[@]}" \
            -f kamu-money-pg/yb/Dockerfile --target artifact \
            --build-arg YB_IMAGE="$YB_REF" \
            --build-arg KMONEY_CACHE_ID="${KMONEY_CACHE_ID:-shared}" -o "$RUN_ROOT" .
    fi

[doc("Build for YB, run the ABI battery on a fresh YugabyteDB, print the result.")]
yb-native tag="":
    #!/usr/bin/env bash
    set -euo pipefail
    source ./kamu-money-pg/yb/workspace-lock.sh
    workspace_lock "yb-native" || exit 1
    # `just yb-build` from the BODY, not as a recipe dependency. just runs a dependency in its own
    # process BEFORE the body, so the build would take the lock and release it again, leaving a
    # window in which another writer claims the default scratch root and overwrites yb/out -- and
    # this recipe would then refuse, after paying for the artifact. Inside the body the exported
    # KMONEY_WORKSPACE_LOCK_FD makes yb-build's acquisition re-entrant, so one hold spans the build
    # and the battery, as it did before the build was extracted.
    just yb-build "{{ tag }}"
    RUN_ROOT="${KMONEY_RUN_ROOT:-kamu-money-pg/yb/out}"
    YB_REF="$(./kamu-money-pg/yb/yb-image.sh {{ tag }})"
    ./kamu-money-pg/yb/run-yb.sh "$YB_REF" "$RUN_ROOT" "$RUN_ROOT/out-yb.txt" kamu-money-pg/yb/abi_battery.sql

# Lock before touching the shared default run root, resolve the default path, and decide the skip.
# The controls themselves are `hygiene/tests/assert_battery.rs`, which refuses to run without an
# output rather than deciding for itself that having none is fine.
[doc("Negative control: prove every battery assertion still rejects a mutated output.")]
yb-selftest out="":
    #!/usr/bin/env bash
    set -euo pipefail
    source ./kamu-money-pg/yb/workspace-lock.sh
    workspace_lock "yb-selftest" || exit 1
    OUT="{{ out }}"
    [ -n "$OUT" ] || OUT="${KMONEY_RUN_ROOT:-kamu-money-pg/yb/out}/out-yb.txt"
    if [ ! -s "$OUT" ]; then
        echo "yb-selftest: SKIP -- no battery output at $OUT (run 'just yb-native' first)" >&2
        exit 0
    fi
    KMONEY_BATTERY_OUTPUT="$OUT" \
        cargo nextest run {{ CORE_PATCH }} -p kamu-money-pg-hygiene --test assert_battery --run-ignored all
[doc("The ported #[pg_test] suite against a live single-node YugabyteDB.")]
test-yb-regress tag="": (yb-build tag)
    #!/usr/bin/env bash
    set -euo pipefail
    ./kamu-money-pg/yb/run-yb-regress.sh "$(./kamu-money-pg/yb/yb-image.sh {{ tag }})"

[doc("kmoney on a 3-node RF=3 cluster: every node, a tablet split, and a missing-library control.")]
test-yb-cluster tag="":
    #!/usr/bin/env bash
    set -euo pipefail
    ./kamu-money-pg/yb/run-yb-cluster.sh "$(./kamu-money-pg/yb/yb-image.sh {{ tag }})"

[doc("kmoney on a read-replica placement: it needs the library too, and fails loudly without it.")]
test-yb-readreplica tag="" replicas="1":
    #!/usr/bin/env bash
    set -euo pipefail
    ./kamu-money-pg/yb/run-yb-readreplica.sh \
        "$(./kamu-money-pg/yb/yb-image.sh {{ tag }})" "" {{ replicas }}

[doc("Concurrent double-entry transfers on a cluster; conservation is the assertion.")]
test-yb-concurrent workers="8" each="25" tag="":
    #!/usr/bin/env bash
    set -euo pipefail
    ./kamu-money-pg/yb/run-yb-concurrent.sh \
        "$(./kamu-money-pg/yb/yb-image.sh {{ tag }})" "" {{ workers }} {{ each }}

[doc("Node restart, node failure with writes continuing, and rejoin -- with kmoney data resident.")]
yb-resilience tag="":
    #!/usr/bin/env bash
    set -euo pipefail
    ./kamu-money-pg/yb/run-yb-resilience.sh "$(./kamu-money-pg/yb/yb-image.sh {{ tag }})"

[doc("Is the YugabyteDB tag still the digest the pgrx fork was validated against? (hits the registry)")]
yb-pin-check tag="":
    #!/usr/bin/env bash
    set -euo pipefail
    echo "pinned:"
    grep -v '^[[:space:]]*#' kamu-money-pg/yb/YB-PINNED.txt | grep -v '^[[:space:]]*$'
    echo "the registry resolves it to:"
    YB_PULL=1 ./kamu-money-pg/yb/yb-image.sh {{ tag }}

[doc("Negative controls for the image pin gate: every refusal path, and both overrides.")]
yb-image-selftest:
    cargo nextest run {{ CORE_PATCH }} -p kamu-money-pg-hygiene --test yb_image --run-ignored all
# The one command whose flag is load-bearing. `cargo update -p kamu-money-core` WITHOUT the patch
# re-locks the lane to whatever crates.io last published, and every container suite then compiles
# the published crate instead of this tree -- silently, because a patch offering a version the
# lockfile does not pin is ignored rather than refused. That has happened once, through a
# dependency bump. `hygiene` now fails on the resulting lockfile, and this recipe is the fix it
# names, so nobody has to reconstruct the quoting.
[doc("Re-lock kamu-money-core against the workspace crate, with the lane patch active.")]
core-relock:
    cargo update {{ CORE_PATCH }} -p kamu-money-core

# Deliberately not a hygiene test: it runs `doc-pg`, so it needs a populated PGRX_HOME, which the
# job running `test-hygiene` does not have. It belongs beside that recipe, in the job that has one.
[doc("Negative controls for the doc gate: a planted link in each region it must reach.")]
doc-gate-selftest:
    cargo nextest run {{ CORE_PATCH }} -p kamu-money-pg-hygiene --test doc_gate --run-ignored all

# Measurements; never gates
[doc("SQL cost: kmoney vs numeric(36,18) on stock PostgreSQL, with the floor. Never a gate.")]
bench-pg major="18":
    ./kamu-money-pg/bench/run-bench-pg.sh {{ major }}

[doc("What a pgrx call costs, against a null C function of the same signature. Never a gate.")]
bench-boundary major="18":
    ./kamu-money-pg/bench/run-bench-boundary.sh {{ major }}

[doc("The pgrx call cost on YugabyteDB, where the multi-threaded memory context lives.")]
bench-boundary-yb tag="":
    ./kamu-money-pg/bench/run-bench-boundary-yb.sh {{ tag }}

[doc("kmoney vs numeric on YugabyteDB: arithmetic, render, parse, storage. Never a gate.")]
bench-sql-yb rows="100000" passes="5" tag="":
    ./kamu-money-pg/bench/run-bench-sql-yb.sh {{ rows }} {{ passes }} "{{ tag }}"

[doc("Why numeric is dear on YugabyteDB: bytea discriminates varlena cost from numeric cost.")]
bench-why-yb rows="100000" passes="9" tag="":
    ./kamu-money-pg/bench/run-bench-sql-yb.sh {{ rows }} {{ passes }} "{{ tag }}" kamu-money-pg/bench/why-numeric-costs.sql

[doc("Baseline: kmoney vs text vs numeric(36,18) on a YugabyteDB cluster. No pass/fail threshold.")]
bench-yb rows="20000" tag="":
    #!/usr/bin/env bash
    set -euo pipefail
    ./kamu-money-pg/yb/run-yb-bench.sh "$(./kamu-money-pg/yb/yb-image.sh {{ tag }})" "" {{ rows }}

[doc("Sustained concurrent double-entry traffic, asserting conservation every round.")]
yb-soak minutes="3" tag="":
    #!/usr/bin/env bash
    set -euo pipefail
    ./kamu-money-pg/yb/run-yb-soak.sh {{ minutes }} "$(./kamu-money-pg/yb/yb-image.sh {{ tag }})"

[private]
_yb-ab-ref base runtime="":
    #!/usr/bin/env bash
    set -euo pipefail
    source ./kamu-money-pg/yb/workspace-lock.sh
    workspace_lock "yb-ab" || exit 1
    RUN_ROOT="${KMONEY_RUN_ROOT:-kamu-money-pg/yb/out}"
    BASE="{{ base }}"
    RUNTIME="{{ runtime }}"
    [ -n "$RUNTIME" ] || RUNTIME="$BASE"
    # The base compiles the artifact and PG15 reference; the runtime boots it.
    for ref in "$BASE" "$RUNTIME"; do
        case "$ref" in
            *sha256:*) ;;
            *)
                echo "_yb-ab-ref: '$ref' is not an immutable reference." >&2
                echo "_yb-ab-ref: this recipe takes resolved identities so that one run is" >&2
                echo "_yb-ab-ref: a claim about one image. Resolve first, or use 'just yb-ab <tag>'." >&2
                exit 2 ;;
        esac
    done
    echo "yb: base identity    $BASE (artifact build and PG15 reference are compiled against this)"
    echo "yb: battery runtime  $RUNTIME"
    source ./scripts/docker-core-context.sh
    if [ "$RUNTIME" = "$BASE" ]; then
        docker build "${KMONEY_CORE_DOCKER_ARGS[@]}" \
            -f kamu-money-pg/yb/Dockerfile --target artifact \
            --build-arg YB_IMAGE="$BASE" \
            --build-arg KMONEY_CACHE_ID="${KMONEY_CACHE_ID:-shared}" -o "$RUN_ROOT" .
    else
        echo "yb: runtime differs from base, so it is a node image that already carries kmoney;"
        echo "yb: no artifact build, and run-yb.sh will refuse to install onto it."
        export YB_REQUIRE_BAKED=1
    fi
    ./kamu-money-pg/yb/run-yb.sh "$RUNTIME" "$RUN_ROOT" "$RUN_ROOT/out-yb.txt" kamu-money-pg/yb/abi_battery.sql
    just yb-selftest "$RUN_ROOT/out-yb.txt"
    docker build "${KMONEY_CORE_DOCKER_ARGS[@]}" \
        -f kamu-money-pg/yb/Dockerfile.pg15 --target ref \
        --build-arg YB_IMAGE="$BASE" -o "$RUN_ROOT/ref" .
    ./kamu-money-pg/yb/assert-battery.sh "$RUN_ROOT/ref/out-pg15.txt" pg15-extracted 0
    norm() { sed -E 's/^(psql|ysqlsh):[^:]*:[0-9]+:/CLIENT:/'; }
    echo "=== A/B diff: YugabyteDB vs stock PG15 -- empty = byte-exact, zero YB edges ==="
    if diff <(norm < "$RUN_ROOT/out-yb.txt") <(norm < "$RUN_ROOT/ref/out-pg15.txt"); then
        echo "yb-ab: BYTE-EXACT -- kmoney behaves identically on YugabyteDB and stock PG15"
    else
        echo "yb-ab: DIVERGENCE (investigate above)"; exit 1
    fi

[doc("Run one byte-exact battery on YugabyteDB and stock PostgreSQL 15.")]
yb-ab tag="":
    #!/usr/bin/env bash
    set -euo pipefail
    source ./kamu-money-pg/yb/workspace-lock.sh
    workspace_lock "yb-ab" || exit 1
    just _yb-ab-ref "$(./kamu-money-pg/yb/yb-image.sh {{ tag }})"

# Operational assurance for whoever runs a cluster, which is why it is not on the release gate:
# replication, tablet placement, read replicas and dump/restore are YugabyteDB's behaviour, and a
# kmoney payload is opaque bytes to DocDB. Run this before adopting a new YugabyteDB image, or when
# changing how the extension is deployed -- not to prove the type is correct.
[doc("Every deployment suite: multi-node, read replica, concurrency, dump and restore.")]
test-yb-deployment tag="": (test-yb-cluster tag) (test-yb-readreplica tag) (test-yb-concurrent "8" "25" tag) (test-yb-restore tag)

[doc("Dump a kmoney schema and restore it into a clean cluster.")]
test-yb-restore tag="":
    #!/usr/bin/env bash
    set -euo pipefail
    ./kamu-money-pg/yb/run-yb-restore.sh "$(./kamu-money-pg/yb/yb-image.sh {{ tag }})"

[doc("Extension + driver: a native kmoney column read through both Rust adapters.")]
test-pg-driver major="18":
    ./kamu-money-pg/native-driver-test.sh {{ major }}

[doc("Test both Rust drivers against a native kmoney column on YugabyteDB.")]
test-yb-driver tag="" major="18":
    ./kamu-money-pg/yb/run-yb-driver.sh "{{ tag }}" "{{ major }}"

[doc("Every supported PostgreSQL major at once, without the YugabyteDB suites.")]
test-pg-matrix: (test-pg PG_MAJORS "4")

[doc("Run every suite that avoids a from-source YugabyteDB build.")]
test-pg-all: test-yb (test-pg PG_MAJORS "4") test-pg-driver test-yb-driver

# Gates
[doc("The gate for a change that touches no database: format, lint, audit, docs, Miri, and offline tests.")]
gate-offline: fmt-check lint deny doc-gate-selftest test-hygiene miri-payload

[doc("The offline gate plus every suite reachable without a from-source YugabyteDB build.")]
gate-pg: gate-offline yb-image-selftest test-pg-all

# THIS GATE PROVES CORRECTNESS, NOT CLUSTER OPERATIONS.
#
# What is this repository's to prove about kmoney on YugabyteDB is that the extension compiled
# against YugabyteDB's PG15 fork behaves identically to one compiled against stock PG15, and that
# the ported case suite passes on a live server. Both are single-node claims: `_yb-ab-ref` is
# byte-exact against upstream PG15, and `run-yb-regress.sh` runs the cases.
#
# Replication factor, tablet placement, read replicas and dump/restore are YugabyteDB's behaviour,
# not the extension's. A `kmoney` payload is opaque bytes to DocDB, so raft copying it faithfully,
# a split relocating it, and a replica serving it are Yugabyte's invariants -- asserting them here
# tests Yugabyte and charges this gate hours for it. They are operational assurance for whoever
# runs a cluster, which this repository does not: the extension is `publish = false` and the node
# image is a test fixture.
#
# So they keep their recipes and leave the gate: `just pg test-yb-deployment` runs all four.
[doc("Run the release gate: the byte-exact A/B and the case suite against a native YugabyteDB.")]
gate-pg-release tag="":
    #!/usr/bin/env bash
    set -euo pipefail

    source ./kamu-money-pg/yb/workspace-lock.sh
    workspace_lock "gate-pg-release" || exit 1

    # Release proof resolves `kamu-money-core` from its version requirement.
    export KMONEY_USE_LOCAL_CORE=0
    # A unique cache scope is an EMPTY BuildKit cache: the release artifact is
    # compiled from scratch, never assembled from a shared incremental cache.
    export KMONEY_CACHE_ID="release-$$-$(od -An -N4 -tx4 /dev/urandom | tr -d ' \n')"
    YB_REF="$(./kamu-money-pg/yb/yb-image.sh {{ tag }})"
    export KMONEY_YB_IMAGE="$YB_REF"

    just gate-pg

    # Every suite boots this node image; no suite installs loose files onto it.
    NODE_IMAGE="$(./kamu-money-pg/yb/node-image.sh "$YB_REF")"
    export YB_REQUIRE_BAKED=1

    source ./kamu-money-pg/yb/install.sh
    RUN_ROOT="${KMONEY_RUN_ROOT:-kamu-money-pg/yb/out}"
    yb_extract_artifact_from_image "$NODE_IMAGE" "$RUN_ROOT"
    yb_resolve_artifacts "$RUN_ROOT"

    # Inspect shipped bytes, not build configuration, for benchmark-only symbols.
    for sym in rs_noop rs_noop_kmoney; do
        if grep -qi "$sym" "$YB_ART_SQL"; then
            echo "gate-pg-release: REFUSING -- the shipped install SQL declares '$sym'." >&2
            echo "gate-pg-release: that is boundary-probe scaffolding and must never be in a" >&2
            echo "gate-pg-release: deployable node image. Rebuild without EXTRA_FEATURES." >&2
            exit 1
        fi
        if nm -D --defined-only "$YB_ART_SO" 2>/dev/null | grep -qi "$sym"; then
            echo "gate-pg-release: REFUSING -- the shipped kmoney.so exports '$sym'." >&2
            exit 1
        fi
    done
    echo "gate-pg-release: the shipped artifact carries no benchmark scaffolding"

    echo "gate-pg-release: base image $YB_REF"
    echo "gate-pg-release: the proofs below boot the NODE IMAGE $NODE_IMAGE"

    # The correctness claim: the extension built against YugabyteDB's PG15 fork behaves
    # BYTE-IDENTICALLY to one built against upstream PG15, and the ported case suite passes on a
    # live server. Everything this repository publishes about YugabyteDB rests on these two.
    just _yb-ab-ref "$YB_REF" "$NODE_IMAGE"
    ./kamu-money-pg/yb/run-yb-regress.sh "$NODE_IMAGE"

    echo "gate-pg-release: all stages green on $NODE_IMAGE"
    echo
    echo "gate-pg-release: PASS"

# Housekeeping
[doc("Report extension-lane containers that outlived their owning test.")]
containers:
    #!/usr/bin/env bash
    set -uo pipefail
    left=$(docker ps -aq --filter 'label=kamu-money-pg.revision' 2>/dev/null)
    if [ -z "$left" ]; then
        echo "clean: no container from this workspace is still around"
        exit 0
    fi
    echo "leftover containers from this workspace:"
    docker ps -a --filter 'label=kamu-money-pg.revision'
    echo
    echo "remove them with: docker rm -f \$(docker ps -aq --filter 'label=kamu-money-pg.revision')"
    exit 1
