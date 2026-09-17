# syntax=docker/dockerfile:1
# Containerised pgrx build + test for one PostgreSQL major.
#
# Nothing is installed on the host: the extension is compiled against this container's PG
# headers and loaded into this container's server. That also turns the PG15..latest matrix into
# a loop over build args rather than a sequence of mutually-exclusive host installs.
#
#   just pg test-pg 18
#
# The whole supported range: `just pg test-pg`.
#
# Keep cargo-pgrx installation above `ARG PG_MAJOR` so the matrix shares that layer.

# The exact patch `rust-toolchain.toml` pins. A series tag floats, and rustup then downloads a
# second toolchain in every container. `hygiene/tests/pins.rs` holds the two equal.
ARG RUST_VERSION=1.96.0
# Also by digest: the tag is rebuilt upstream on distribution patches, so it names different
# bytes over time.
FROM rust:${RUST_VERSION}-trixie@sha256:58fe97504a0e4cbba5d85599619a589923d3e779472a6fb0840d58d1c4ba99d7 AS builder

# Docker resolves the digest and ignores the tag, so nothing outside this build can hold the two
# together.
ARG RUST_VERSION
RUN test "$(rustc --version | cut -d' ' -f2)" = "$RUST_VERSION" \
    || { echo "base image is not rustc $RUST_VERSION; its digest names another toolchain" >&2; exit 1; }

# Must match the `pgrx` dependency in kamu-money-pg/Cargo.toml exactly. cargo-pgrx refuses to build
# an extension whose pgrx version differs from its own — a good refusal, since the generated
# SQL and the FFI shims are versioned together.
ARG PGRX_VERSION=0.19.2

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg lsb-release \
    && rm -rf /var/lib/apt/lists/*

# Install optional trust anchors before any HTTPS fetch. The default directory contains only a
# README; update-ca-certificates ignores it. See kamu-money-pg/ca-certs/README.md.
COPY kamu-money-pg/ca-certs/ /usr/local/share/ca-certificates/
RUN update-ca-certificates

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential libclang-dev clang jq pkg-config \
        libreadline-dev zlib1g-dev flex bison \
        libxml2-dev libxslt1-dev libssl-dev libxml2-utils xsltproc \
    && install -d /usr/share/postgresql-common/pgdg \
    && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
         -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
    && echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] \
         https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
         > /etc/apt/sources.list.d/pgdg.list \
    && rm -rf /var/lib/apt/lists/*

# PostgreSQL refuses to run as root and `cargo pgrx test` starts a server, so both the build
# and the test run unprivileged.
RUN useradd -m -s /bin/bash pgrx
USER pgrx
ENV PATH="/home/pgrx/.cargo/bin:${PATH}" CARGO_HOME=/home/pgrx/.cargo

# Shared across the PostgreSQL matrix.
RUN cargo install cargo-pgrx --version "=${PGRX_VERSION}" --locked

ARG PG_MAJOR=18
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
        "postgresql-${PG_MAJOR}" "postgresql-server-dev-${PG_MAJOR}" \
    && rm -rf /var/lib/apt/lists/* \
    # pgrx installs test artifacts into distro-owned directories. Grant this disposable,
    # single-purpose container's build user access; never apply this ownership change to a host.
    && PGC="/usr/lib/postgresql/${PG_MAJOR}/bin/pg_config" \
    && chown -R pgrx:pgrx "$("$PGC" --sharedir)/extension" "$("$PGC" --pkglibdir)"
USER pgrx

# pgrx-tests reads `$USER`; Docker's USER instruction does not export it.
ENV USER=pgrx

# Point pgrx at the PG this image already has rather than letting it compile another one.
RUN cargo pgrx init "--pg${PG_MAJOR}" "/usr/lib/postgresql/${PG_MAJOR}/bin/pg_config"

# Carried as an environment variable so the stages below inherit it. An ARG stops at its stage,
# and a later `${PG_MAJOR}` that nobody redeclared expands to nothing rather than failing.
ENV PG_MAJOR=${PG_MAJOR}

WORKDIR /work

# Repository configuration forces PGRX_HOME to `/work/.pgrx`; link it to the cached home created
# above. It has to exist before anything runs cargo, because `pgrx-pg-sys`'s build script reads
# that directory to find the pg_config it generates bindings against.
RUN ln -s /home/pgrx/.pgrx /work/.pgrx

# --- the lane's own build ---------------------------------------------------------------------
# Everything above is the reusable builder, published on its own. The one repository-specific
# part is the /work/.pgrx link, which an extension built elsewhere ignores.
FROM builder AS lane

# Ordinary test builds use the normalized Cargo package supplied as a named
# context. Release proof sets this to 0, leaving the plain version dependency to
# resolve exclusively from crates.io.
#
# This lands ABOVE the dependency build so that both compile the same graph. Resolving
# `kamu-money-core` one way here and the other way below would make the cached layer a lie.
ARG KMONEY_USE_LOCAL_CORE=1
COPY --from=kamu-money-core --chown=pgrx:pgrx . /opt/kamu-money-core

# --- dependency layer -----------------------------------------------------------------------
# Manifests, lockfile and Cargo configuration only, with a stub source tree standing in for the
# real one. Compiling that builds every DEPENDENCY -- `pgrx` and `pgrx-pg-sys` dominate, bindgen
# included -- into a layer keyed by the manifests alone, so editing `src/` recompiles
# `kamu-money-pg` and nothing beneath it.
#
# This is also the ONLY form a CI cache can reach. The extension itself is compiled by this
# image's `CMD`, at container run time, where no registry cache exists; BuildKit exports layers,
# never `--mount=type=cache` directories. Moving the expensive half into a layer is what makes
# `cache-from`/`cache-to` possible at all.
#
# `build.rs` is copied rather than stubbed: it is the per-currency generator, so keeping it real
# puts its `kamu-money-core` build-dependency in the layer too, and a change to it correctly
# invalidates. Its output is never compiled here, because the stub `lib.rs` does not include it.
COPY --chown=pgrx Cargo.toml Cargo.lock rust-toolchain.toml ./
COPY --chown=pgrx .cargo/ .cargo/
COPY --chown=pgrx kamu-money-pg/Cargo.toml kamu-money-pg/build.rs kamu-money-pg/
COPY --chown=pgrx hygiene/Cargo.toml hygiene/
COPY --chown=pgrx scripts/assert-core-resolution.sh scripts/
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
    # `--tests` so the dev-dependencies land here too; `pgrx-tests` is one, and the CMD needs it.
    cargo build -p kamu-money-pg --tests --no-default-features --features "pg${PG_MAJOR}"
    rm -rf kamu-money-pg/src hygiene/src
SETUP

# --- the real source ------------------------------------------------------------------------
# `.dockerignore` keeps `target`, `.pgrx` and the suites' scratch root out, so this neither
# clobbers the artifacts just built nor the symlink above.
COPY --chown=pgrx . .

# Again, and not redundantly: the copy above restored the tracked `.cargo/config.toml`, taking
# the patch block with it. Without this the CMD would resolve `kamu-money-core` from the
# registry while the cached layer was built against the local path.
#
# The assertion is repeated for the same reason the append is: this is the resolution the CMD's
# tests actually run against, and losing the patch here would be invisible in their results.
RUN case "${KMONEY_USE_LOCAL_CORE}" in \
      0) echo "kamu-money-core: resolving from crates.io"; WANT=registry ;; \
      1) printf '\n[patch.crates-io]\nkamu-money-core = { path = "/opt/kamu-money-core" }\n' \
           >> /work/.cargo/config.toml; WANT=local ;; \
      *) echo "KMONEY_USE_LOCAL_CORE must be 0 or 1" >&2; exit 2 ;; \
    esac; \
    bash scripts/assert-core-resolution.sh "$WANT"
ENV KMONEY_USE_LOCAL_CORE=${KMONEY_USE_LOCAL_CORE}

# Exists (pgrx-owned, and now carrying the compiled dependencies) so that a named cache volume
# mounted here by test-matrix.sh is seeded with THIS ownership and THIS content. Docker seeds a
# fresh named volume from the image path; without this the volume arrives root-owned and cargo
# cannot write to it.
RUN mkdir -p /work/target

CMD ["bash", "-c", "exec cargo pgrx test --no-default-features --features \"pg${PG_MAJOR}\" \"pg${PG_MAJOR}\""]
