# syntax=docker/dockerfile:1
# Build kamu-money-pg (kmoney) against YugabyteDB's PG15 fork, to PROVE native YB
# support (operator directive: YB is first-class). Built FROM the YB image so
# glibc/OS and the PG15 headers match the runtime exactly -- the only thing that
# makes the ABI byte-correct rather than merely loadable.
#
# The three-symbol adaptation now lives in the pgrx fork the workspace root patches in
# (pgrx-yugabytedb, tag v0.19.2-yb.1), behind its `yb-pg15` feature -- it is no longer vendored
# and textually patched here. Build through `just pg yb-build`; the recipe supplies
# the lane context plus the normalized kamu-money-core named context.
ARG YB_IMAGE=yugabytedb/yugabyte:2025.2.5.1-b1
FROM ${YB_IMAGE} AS deps
USER root

# YB's base is UBI/CentOS-family; use dnf or yum. libclang is needed by pgrx's
# bindgen against YB's server headers.
RUN (command -v dnf >/dev/null 2>&1 && \
     dnf install -y curl gcc gcc-c++ make clang clang-devel llvm-libs \
       bison flex readline-devel zlib-devel libicu-devel openssl-devel ca-certificates \
     || yum install -y curl gcc gcc-c++ make clang clang-devel llvm-libs \
       bison flex readline-devel zlib-devel libicu-devel openssl-devel ca-certificates)

# Optional TLS-inspecting-proxy trust anchors, same rule as kamu-money-pg/Dockerfile:
# on a network that re-signs TLS, cargo/rustup's HTTPS dies without the host CA.
# Only .crt files matter; the directory usually holds just a README (no-op).
COPY kamu-money-pg/ca-certs/ /etc/pki/ca-trust/source/anchors/
RUN update-ca-trust extract || true
ENV SSL_CERT_FILE=/etc/pki/tls/certs/ca-bundle.crt \
    CARGO_HTTP_CAINFO=/etc/pki/tls/certs/ca-bundle.crt

RUN curl --proto '=https' --tlsv1.2 -sSfo /tmp/rustup.sh https://sh.rustup.rs \
 && sh /tmp/rustup.sh -y --default-toolchain 1.96.0
ENV PATH=/root/.cargo/bin:$PATH
RUN cargo install cargo-pgrx --version 0.19.2 --locked
ENV RUST_BACKTRACE=1

# `.cargo/config.toml` forces PGRX_HOME=<workspace>/.pgrx (relative, force=true), but
# `cargo pgrx init` does NOT honour that [env] and writes to the default /root/.pgrx,
# while the pgrx-pg-sys BUILD SCRIPT (run under cargo) DOES honour it and looks for
# /work/.pgrx -> "$PGRX_HOME does not exist". A symlink reconciles the two, exactly as
# kamu-money-pg/Dockerfile does (there the init user is pgrx; here it is root).
#
# It has to exist before ANYTHING runs cargo, which is why it now precedes the dependency layer
# instead of following a source copy. Neither step needs source to run.
RUN cargo pgrx init --pg15 /home/yugabyte/postgres/bin/pg_config
WORKDIR /work
RUN ln -sfn /root/.pgrx /work/.pgrx

# FIRST assert this image's headers still have the shape the adaptations were derived against.
#
# The compiler cannot replace this probe, even now that the adaptations live in a pgrx fork rather
# than in textual patches. A patch that no longer APPLIES is a build failure by construction; a
# patch may still compile after the underlying header contract changes. The probe checks the
# assumed header shape before ANY compile -- which is why it is copied on its own, ahead of the
# dependency layer, rather than arriving with the rest of the source. It reads this image's
# headers and nothing else, so keeping it first costs one small file.
COPY kamu-money-pg/yb/probe-yb-abi.sh kamu-money-pg/yb/
RUN chmod +x kamu-money-pg/yb/probe-yb-abi.sh && ./kamu-money-pg/yb/probe-yb-abi.sh

# Keep the lane as the primary context. A second context carries only Cargo's
# normalized kamu-money-core package; release proof disables its Cargo patch.
#
# This lands ABOVE the dependency layer so that the layer and the package step compile the same
# graph. Resolving `kamu-money-core` one way here and the other way there would make the cached
# layer a lie.
ARG KMONEY_USE_LOCAL_CORE=1
COPY --from=kamu-money-core . /opt/kamu-money-core

# --- dependency layer ---------------------------------------------------------------------------
# Manifests, lockfile and Cargo configuration only, with a stub source tree standing in for the
# real one. Compiling that builds every DEPENDENCY -- the pgrx fork and pgrx-pg-sys dominate,
# bindgen against YugabyteDB's own PG15 headers included -- into a layer keyed by the manifests
# alone, so editing `src/` recompiles `kamu-money-pg` and nothing beneath it.
#
# This is also the ONLY form a CI cache can reach, and the reason the compile no longer happens
# inside a BuildKit cache mount. BuildKit exports LAYERS; a mount is builder-local and never leaves
# the machine that filled it, so a fresh runner had nothing to restore and rebuilt the whole
# dependency graph every run. The two are mutually exclusive on the same path -- a mount over
# /work/target masks whatever a layer baked there -- so this replaces them rather than joining them.
#
# `--release`, because `cargo pgrx package` builds the release profile and `[profile.release]` sets
# `lto = "fat"`, which changes how every dependency rlib is compiled. A dev-profile layer would be
# reused by nothing.
#
# `build.rs` is copied rather than stubbed: it is the per-currency generator, so keeping it real
# puts its `kamu-money-core` build-dependency in the layer too, and a change to it correctly
# invalidates. Its output is never compiled here, because the stub `lib.rs` does not include it.
#
# No `EXTRA_FEATURES` here. `boundary-probe` adds two no-op externs and no dependency, so one layer
# serves the deployable build and the measurement build alike.
COPY Cargo.toml Cargo.lock rust-toolchain.toml ./
COPY .cargo/ .cargo/
COPY kamu-money-pg/Cargo.toml kamu-money-pg/build.rs kamu-money-pg/
COPY hygiene/Cargo.toml hygiene/
COPY scripts/assert-core-resolution.sh scripts/

# The release proof's empty-cache guarantee, and the reason this ARG is EXPANDED in the RUN below
# rather than merely declared beside it: BuildKit keys a RUN on its expanded command, so a unique
# KMONEY_CACHE_ID is a guaranteed miss and therefore a genuine from-scratch dependency compile.
# `just gate-pg-release` derives one per run, exactly as it did when this scoped a cache mount.
#
# An ARG declared and never referenced would scope nothing at all, and would say so nowhere --
# which is why `hygiene/tests/packaging.rs` asserts the reference below, not just the declaration.
ARG KMONEY_CACHE_ID=shared
RUN <<'SETUP' bash -e
    case "${KMONEY_USE_LOCAL_CORE}" in
      0) echo "kamu-money-core: resolving from crates.io"; WANT=registry ;;
      1) printf '\n[patch.crates-io]\nkamu-money-core = { path = "/opt/kamu-money-core" }\n' \
           >> /work/.cargo/config.toml; WANT=local ;;
      *) echo "KMONEY_USE_LOCAL_CORE must be 0 or 1" >&2; exit 2 ;;
    esac
    mkdir -p kamu-money-pg/src hygiene/src
    : > kamu-money-pg/src/lib.rs
    : > hygiene/src/lib.rs
    # Appending the patch is not the same as Cargo using it. Fail here, before a compile whose
    # result would silently describe the published crate rather than this tree.
    #
    # BELOW the stubs, because Cargo refuses to load a workspace member whose lib target has no
    # file -- and an assertion that cannot resolve anything refuses every lockfile, correct ones
    # included, which is a guard that proves nothing while looking strict.
    bash scripts/assert-core-resolution.sh "$WANT"
    echo "dependency scope: ${KMONEY_CACHE_ID}"
    cargo build --release -p kamu-money-pg --no-default-features --features "pg15,yb-pg15"
    rm -rf kamu-money-pg/src hygiene/src
SETUP

# =================================================================================================
# The extension itself, on top of the dependencies above.
FROM deps AS build

# --- the real source ----------------------------------------------------------------------------
# `.dockerignore` keeps `target`, `.pgrx` and the suites' scratch root out, so this clobbers
# neither the dependencies just compiled nor the PGRX_HOME symlink.
COPY . .

# Again, and not redundantly: the copy above restored the tracked `.cargo/config.toml`, taking the
# patch block with it. Without this the package step would resolve `kamu-money-core` from the
# registry while the layer beneath it was built against the local path.
#
# The assertion is repeated for the same reason the append is: this is the resolution the SHIPPED
# library is compiled against, and losing the patch here would be invisible in the artifact.
ARG KMONEY_USE_LOCAL_CORE=1
RUN case "${KMONEY_USE_LOCAL_CORE}" in \
      0) echo "kamu-money-core: resolving from crates.io"; WANT=registry ;; \
      1) printf '\n[patch.crates-io]\nkamu-money-core = { path = "/opt/kamu-money-core" }\n' \
           >> /work/.cargo/config.toml; WANT=local ;; \
      *) echo "KMONEY_USE_LOCAL_CORE must be 0 or 1" >&2; exit 2 ;; \
    esac; \
    bash scripts/assert-core-resolution.sh "$WANT"
ENV KMONEY_USE_LOCAL_CORE=${KMONEY_USE_LOCAL_CORE}

# Package kamu-money-pg (PG15) against YB's own pg_config.
#
# The three adaptations live behind `yb-pg15` in the pgrx fork patched by the workspace root.
# This build selects that feature; it does not vendor or text-patch generated bindings.
#
# `--features pg15,yb-pg15`, not RUSTFLAGS="--cfg yb": a cfg set through RUSTFLAGS is global,
# leaks into every crate in the build, and leaves nothing in any manifest saying this build
# targets YugabyteDB. The two features are ORTHOGONAL -- pg15 picks the major, yb-pg15 picks the
# fork's adaptations for that major.
#
# --no-default-features because kamu-money-pg defaults to pg18; YugabyteDB 2025.2.x is PG15.
#
# `EXTRA_FEATURES` is EMPTY by default, so the release path builds exactly what it always built.
# Its only use is `boundary-probe`, which adds two no-op `#[pg_extern]`s that exist to be
# measured (kamu-money-pg/bench/boundary/). They must never reach a deployable node image, and
# with an empty default they cannot arrive by accident -- a caller has to name them.
ARG EXTRA_FEATURES=
RUN cargo pgrx package -p kamu-money-pg \
      --no-default-features --features "pg15,yb-pg15${EXTRA_FEATURES:+,$EXTRA_FEATURES}" \
      -c /home/yugabyte/postgres/bin/pg_config

# EXACTLY ONE of each, asserted rather than assumed, plus a manifest the host side verifies.
#
# The selector is kamu-money-pg/yb/exactly-one.sh: it refuses on any count but one, and names the
# paths it found. Keeping it in a file rather than inline is what lets
# hygiene/tests/exactly_one.rs falsify it -- an assertion that only ever runs inside a
# Docker build has no negative control short of a build argument invented to break it.
#
# ARTIFACT-MANIFEST.txt is `sha256sum`'s own format, so kamu-money-pg/yb/artifact.sh verifies it
# with `sha256sum -c` rather than a hand-rolled comparison -- which is what makes a stale file
# left in the output directory a failure instead of a coin flip.
RUN set -eux; mkdir -p /out; \
    chmod +x kamu-money-pg/yb/exactly-one.sh; \
    one() { ./kamu-money-pg/yb/exactly-one.sh target "$1"; }; \
    cp "$(one 'kmoney*.so')"     /out/kmoney.so; \
    cp "$(one 'kmoney.control')" /out/kmoney.control; \
    cp "$(one 'kmoney--*.sql')"  /out/; \
    cd /out && sha256sum kmoney.so kmoney.control kmoney--*.sql > ARTIFACT-MANIFEST.txt && \
    cat ARTIFACT-MANIFEST.txt

FROM scratch AS artifact
COPY --from=build /out/ /

# =================================================================================================
# THE DEPLOYABLE NODE IMAGE. This is how the extension reaches production, and the `artifact`
# stage above is only how it reaches this stage.
#
# WHY AN IMAGE RATHER THAN AN INSTALL STEP. Installing onto running nodes does not scale and
# cannot survive a node being replaced: you must enumerate every tserver, remember that read
# replicas are tservers too, and redo it for every node that is ever rebuilt, autoscaled or
# recovered. Baking it in makes "is the extension on every node?" the same question as "is every
# node running image digest D?" -- which the orchestrator already answers, and which is exactly
# the identity discipline yb-image.sh already applies to the BASE image one level down.
#
# It also collapses the whole primary-versus-read-replica and RF3-versus-RF5 distinction: there is
# one image, and a node either boots from it or does not exist.
#
# WHAT IT DOES NOT SOLVE, because files are not the whole story: `CREATE EXTENSION` and
# `ALTER EXTENSION UPDATE` are CATALOG state, once per cluster, not per node. So the ordering that
# survives is ordinary PostgreSQL extension discipline -- roll the image everywhere first (the new
# library must still serve the CURRENT catalog version), then update the catalog once, then recycle
# connections, because `module_pathname = 'kmoney'` means live backends keep the old library
# loaded. See RUNBOOK.md, "Extension version changes".
#
#   just pg yb-node-image
FROM ${YB_IMAGE} AS node
COPY --from=build /out/kmoney.so             /home/yugabyte/postgres/lib/kmoney.so
COPY --from=build /out/kmoney.control        /home/yugabyte/postgres/share/extension/
COPY --from=build /out/kmoney--*.sql         /home/yugabyte/postgres/share/extension/
# The manifest travels WITH the library, so a node can be asked what it is carrying without
# reference to the build host that produced it.
COPY --from=build /out/ARTIFACT-MANIFEST.txt /home/yugabyte/postgres/share/extension/kmoney-ARTIFACT-MANIFEST.txt

# Fail the BUILD, not the first query, if the paths above are wrong for this base image. A COPY to
# a mistyped directory succeeds silently by creating it.
RUN set -eux; \
    test -f /home/yugabyte/postgres/lib/kmoney.so; \
    test -f /home/yugabyte/postgres/share/extension/kmoney.control; \
    ls /home/yugabyte/postgres/share/extension/kmoney--*.sql >/dev/null; \
    cd /home/yugabyte/postgres/share/extension && \
    sed 's#  kmoney.so#  /home/yugabyte/postgres/lib/kmoney.so#' kmoney-ARTIFACT-MANIFEST.txt \
      | sha256sum -c -

# =================================================================================================
# THE BOUNDARY-PROBE NODE. A MEASUREMENT ARTEFACT, NEVER A DEPLOYABLE ONE.
#
#   just pg bench-boundary-yb
#
# WHY IT NEEDS ITS OWN TARGET. The probe compares a null `#[pg_extern]` against a null C function
# of the same signature, and the subtraction only means anything if BOTH were compiled against
# the same server headers and load into the same backend. On YugabyteDB that means YB's own
# PG15 headers and YB's glibc. A `c_noop.so` compiled elsewhere measures a different ABI or may
# not load.
#
# The runtime image has no compiler, so the .so is built in the `build` stage, which does.
#
# `EXTRA_FEATURES=boundary-probe` reaches the `build` stage through the ARG above and is what
# puts `rs_noop`/`rs_noop_kmoney` into the extension. probe.sql REFUSES to print a table if they
# are absent, so a caller who forgets the build-arg gets a refusal rather than a boundary
# measurement with no pgrx side in it.
#
# NOT the `node` target, and the separation is the point: `node` is what the release gate
# certifies and what an orchestrator deploys, and it must never carry a function whose only
# purpose is to be timed.
FROM build AS boundary-build
RUN gcc -O2 -fPIC -shared \
      -I"$(/home/yugabyte/postgres/bin/pg_config --includedir-server)" \
      -o /out/c_noop.so kamu-money-pg/bench/boundary/c_noop.c

FROM node AS boundary-node
# A stable path under the server's own lib directory, so the probe names one location on both
# engines rather than depending on where a runner happened to copy it.
COPY --from=boundary-build /out/c_noop.so /home/yugabyte/postgres/lib/c_noop.so
COPY kamu-money-pg/bench/boundary/probe.sql /home/yugabyte/probe.sql
# Fail the BUILD if the probe functions are missing from the SQL this image carries, rather than
# discovering it after a node has booted and a measurement has been set up.
RUN set -eux; \
    test -f /home/yugabyte/postgres/lib/c_noop.so; \
    grep -q 'rs_noop' /home/yugabyte/postgres/share/extension/kmoney--*.sql \
      || { echo "boundary-node: the extension was built WITHOUT --build-arg EXTRA_FEATURES=boundary-probe" >&2; exit 1; }
