mod support;

use cargo_metadata::DependencyKind;

#[test]
fn docker_context_excludes_host_state() {
    let root = support::lane_root();
    let ignore = support::read(root.join(".dockerignore"));
    let patterns: Vec<_> =
        ignore.lines().map(str::trim).filter(|line| !line.is_empty() && !line.starts_with('#')).collect();

    for required in [".pgrx", "target", "kamu-money-pg/yb/out"] {
        assert!(patterns.contains(&required), ".dockerignore must exclude {required:?}");
    }
}

#[test]
fn docker_builds_share_the_normalized_core_package() {
    let root = support::lane_root();
    let repository = support::repository_root();
    let helper = support::read(root.join("scripts/docker-core-context.sh"));
    for required in ["cargo package", "tests/pg_native_column.rs", "--build-context", "KMONEY_USE_LOCAL_CORE"]
    {
        assert!(helper.contains(required), "Docker context helper must contain {required:?}");
    }

    let core = support::manifest(repository.join("crates/money-core/Cargo.toml"));
    let include = core["package"]["include"].as_array().expect("money-core package.include must be an array");
    assert!(
        include.iter().any(|entry| entry.as_str() == Some("tests/**/*.rs")),
        "the normalized core package must include native-column integration tests"
    );

    for dockerfile in
        ["kamu-money-pg/Dockerfile", "kamu-money-pg/yb/Dockerfile", "kamu-money-pg/yb/Dockerfile.pg15"]
    {
        let source = support::read(root.join(dockerfile));
        for required in ["--from=kamu-money-core", "KMONEY_USE_LOCAL_CORE", "[patch.crates-io]"] {
            assert!(source.contains(required), "{dockerfile} must contain {required:?}");
        }
    }

    for caller in [
        "Justfile",
        "kamu-money-pg/test-matrix.sh",
        "kamu-money-pg/native-driver-test.sh",
        "kamu-money-pg/yb/run-yb-driver.sh",
        "kamu-money-pg/yb/node-image.sh",
        "kamu-money-pg/bench/run-bench-boundary-yb.sh",
    ] {
        // `docker buildx build` is a build too. Matching only the bare form would let a buildx
        // invocation resolve kamu-money-core differently from its siblings and say nothing,
        // which is the failure this guard exists to make impossible.
        let source = support::read(root.join(caller));
        let builds: Vec<&str> = source
            .lines()
            .filter(|line| {
                let trimmed = line.trim_start();
                !trimmed.starts_with('#')
                    && (trimmed.contains("docker build") || trimmed.contains("docker buildx build"))
            })
            .collect();

        // A positive control. Composing the command in one place and the context in another --
        // `cmd=(docker build)` here, `"${cmd[@]}" "${ARGS[@]}"` there -- leaves nothing for the
        // loop below to inspect, and that silence reads exactly like compliance.
        assert!(
            !builds.is_empty(),
            "{caller} no longer names a Docker build on any line, so this guard would pass \
             vacuously; keep the command and the core context together, or re-point the guard"
        );

        for line in builds {
            assert!(
                line.contains("KMONEY_CORE_DOCKER_ARGS"),
                "{caller} has a Docker build without the normalized core context: {line}"
            );
        }
    }

    let dump = support::just_dump(&root);
    let release = support::recipe_body(&dump, "gate-pg-release");
    assert!(
        release.contains("export KMONEY_USE_LOCAL_CORE=0"),
        "release proof must resolve money-core from the registry"
    );

    let workflow = support::read(repository.join(".github/workflows/on-pr-synced.yml"));
    assert!(
        !workflow.contains("money-core-published"),
        "ordinary container CI must not wait for first publication"
    );
}

/// `Cargo.lock` must lock `kamu-money-core` at the version the workspace crate carries.
///
/// That equality, not the entry's form, is the precondition for the lane's patch. A patch is
/// ignored when the version it offers is not the version the lockfile pins: Cargo says so in a
/// warning and then compiles the published crate instead, and every build still succeeds. That is
/// how this lane spent a release cycle testing kamu-money-core 0.1.1 while the tree carried 0.1.2,
/// after a dependency bump ran bare `cargo update` here. Nothing failed, because the guards asked
/// whether the named Docker context was PASSED, and it was.
///
/// The entry's form is deliberately NOT asserted, because it cannot be stable. Cargo records the
/// resolution it just performed: a patched run rewrites the entry to a path (no `source`), an
/// unpatched one rewrites it back to the registry. Every lane recipe patches, but a `cargo
/// metadata` from an editor does not, so pinning the form would turn an ordinary background
/// process into a gate failure while catching nothing the version check misses. What must hold is
/// that whichever form is committed names the same version the tree does.
#[test]
fn the_lane_lockfile_resolves_money_core_through_the_patch() {
    let lock = support::manifest(support::lane_root().join("Cargo.lock"));
    let packages = lock["package"].as_array().expect("Cargo.lock must contain a package array");

    // A positive control for the `source` inspection below: if this parse could not see the key at
    // all, "no source" would mean "no idea" and every registry entry would read as patched.
    assert!(
        packages.iter().any(|package| package.get("source").is_some()),
        "no locked package carries a `source`, so this parse cannot distinguish a patched entry \
         from a registry one; re-point the guard"
    );

    let entry = packages
        .iter()
        .find(|package| package["name"].as_str() == Some("kamu-money-core"))
        .expect("the lane must lock kamu-money-core");

    // Derived, not restated: the pin cannot drift from the crate it is supposed to be.
    let tree = support::manifest(support::repository_root().join("crates/money-core/Cargo.toml"));
    assert_eq!(
        entry["version"].as_str(),
        tree["package"]["version"].as_str(),
        "the lane locks a kamu-money-core version the workspace does not carry, so the patch \
         offers a version the lockfile does not pin and Cargo IGNORES it -- every container suite \
         would compile the published crate rather than this tree. Re-lock with the patch active: \
         just pg core-relock"
    );

    // A registry entry must stay verifiable. A `source` without a `checksum` is neither a patched
    // entry nor a checked one.
    if entry.get("source").is_some() {
        assert!(
            entry.get("checksum").is_some(),
            "kamu-money-core is locked to a registry source with no checksum"
        );
    }
}

/// One `FROM` stage: its alias, what it descends from, the build arguments it declares, and its
/// RUN instructions with comment lines removed.
struct Stage {
    name: Option<String>,
    parent: String,
    args: Vec<String>,
    runs: Vec<String>,
}

/// Parse a Dockerfile into stages.
///
/// Three things a line-oriented reading gets wrong, each of which would let a guard below pass on a
/// Dockerfile it exists to reject:
///
/// * `ARG` is STAGE-scoped. A declaration in a sibling stage is not a declaration in this one: the
///   `--build-arg` arrives unconsumed, Docker only warns, the expansion resolves to the empty
///   string, and the layer key stops varying while the file still reads correct.
/// * A RUN spans its backslash continuations and its `<<'HEREDOC'` body, because BuildKit keys the
///   layer on the whole expanded command. Reading single lines would see an argument's expansion
///   and the compile it scopes as unrelated.
/// * COMMENTS ARE NOT CODE. A comment naming `${KMONEY_CACHE_ID}` must not satisfy a guard looking
///   for the expansion, and a comment naming `--mount=type=cache` -- this Dockerfile carries one,
///   explaining why the mounts were removed -- must not fail a guard looking for the mount.
fn stages(dockerfile: &str) -> Vec<Stage> {
    let lines: Vec<&str> = dockerfile.lines().collect();
    let mut stages: Vec<Stage> = Vec::new();
    let mut index = 0;

    while index < lines.len() {
        let line = lines[index];
        index += 1;
        let trimmed = line.trim_start();

        if let Some(rest) = trimmed.strip_prefix("FROM ") {
            let mut words = rest.split_whitespace();
            let parent = words.next().unwrap_or_default().to_owned();
            let name = match (words.next(), words.next()) {
                (Some(keyword), Some(alias)) if keyword.eq_ignore_ascii_case("as") => Some(alias.to_owned()),
                _ => None,
            };
            stages.push(Stage { name, parent, args: Vec::new(), runs: Vec::new() });
            continue;
        }

        // An `ARG` above the first `FROM` belongs to no stage, which is exactly what Docker says
        // about it too.
        let Some(stage) = stages.last_mut() else { continue };

        if let Some(rest) = trimmed.strip_prefix("ARG ") {
            stage.args.push(rest.split('=').next().unwrap_or_default().trim().to_owned());
            continue;
        }

        if !trimmed.starts_with("RUN ") {
            continue;
        }

        let mut instruction = line.to_owned();
        let heredoc = line
            .split_once("<<")
            .map(|(_, rest)| {
                rest.split_whitespace().next().unwrap_or_default().trim_matches(['\'', '"', '-']).to_owned()
            })
            .filter(|delimiter| !delimiter.is_empty());

        match heredoc {
            Some(delimiter) => {
                while index < lines.len() {
                    let next = lines[index];
                    index += 1;
                    instruction.push('\n');
                    instruction.push_str(next);
                    if next.trim() == delimiter {
                        break;
                    }
                }
            }
            None => {
                while instruction.trim_end().ends_with('\\') && index < lines.len() {
                    instruction.push('\n');
                    instruction.push_str(lines[index]);
                    index += 1;
                }
            }
        }

        let code: Vec<&str> =
            instruction.lines().filter(|line| !line.trim_start().starts_with('#')).collect();
        stage.runs.push(code.join("\n"));
    }

    stages
}

/// The stage that both DECLARES `KMONEY_CACHE_ID` and EXPANDS it in the RUN that compiles.
fn scoped_dependency_stage(stages: &[Stage]) -> Option<usize> {
    stages.iter().position(|stage| {
        stage.args.iter().any(|arg| arg == "KMONEY_CACHE_ID")
            && stage
                .runs
                .iter()
                .any(|run| run.contains("cargo build --release") && run.contains("${KMONEY_CACHE_ID}"))
    })
}

fn stage_running(stages: &[Stage], command: &str) -> Option<usize> {
    stages.iter().position(|stage| stage.runs.iter().any(|run| run.contains(command)))
}

/// Whether `index` is `ancestor`, or descends from it through `FROM <stage>` links.
fn descends_from(stages: &[Stage], index: usize, ancestor: usize) -> bool {
    let mut current = index;
    let mut hops = 0;
    while hops <= stages.len() {
        if current == ancestor {
            return true;
        }
        let parent = stages[current].parent.as_str();
        match stages.iter().position(|stage| stage.name.as_deref() == Some(parent)) {
            Some(next) => current = next,
            None => return false,
        }
        hops += 1;
    }
    false
}

fn scopes_the_dependency_compile(dockerfile: &str) -> bool {
    scoped_dependency_stage(&stages(dockerfile)).is_some()
}

fn mounts_a_cache(dockerfile: &str) -> bool {
    stages(dockerfile).iter().any(|stage| stage.runs.iter().any(|run| run.contains("--mount=type=cache")))
}

/// The YugabyteDB dependency compile must be scoped by `KMONEY_CACHE_ID`, EXPANDED inside the
/// instruction that performs it.
///
/// `gate-pg-release` derives a value per run that no other run has used. While the compile lived
/// in a BuildKit cache mount, that made the mount empty by definition. It now busts the dependency
/// LAYER, by the same mechanism and for the same reason: BuildKit keys a RUN on its expanded
/// command, so an unseen value is a guaranteed miss and therefore a genuine from-scratch build.
///
/// What this exists to make impossible is an ARG declared and never referenced. It scopes nothing,
/// changes no cache key, and reads exactly like a build argument that works -- so the release proof
/// would go on claiming a from-scratch compile while assembling one out of whatever the daemon had.
#[test]
fn the_release_proof_compiles_the_yb_dependencies_from_empty() {
    let root = support::lane_root();
    let dockerfile = support::read(root.join("kamu-money-pg/yb/Dockerfile"));
    let parsed = stages(&dockerfile);

    let scoped = scoped_dependency_stage(&parsed).unwrap_or_else(|| {
        panic!(
            "the YugabyteDB dependency compile must DECLARE KMONEY_CACHE_ID in its own stage and \
             EXPAND it in the same RUN that runs `cargo build --release`"
        )
    });

    // The scope only reaches the shipped library if the package step inherits that layer. While
    // the argument sat on the package RUN itself the relationship could not be broken; now it is
    // inherited, and re-parenting the stage would sever it without touching anything asserted above.
    let packaging = stage_running(&parsed, "cargo pgrx package")
        .expect("the YugabyteDB image must run `cargo pgrx package`");
    assert!(
        descends_from(&parsed, packaging, scoped),
        "the stage running `cargo pgrx package` does not descend from the scoped dependency stage, \
         so a unique KMONEY_CACHE_ID no longer busts what the shipped library is built on"
    );

    // Controls. Without them this guard would pass on every shape it exists to reject.
    assert!(
        scopes_the_dependency_compile(concat!(
            "FROM base AS deps\nARG KMONEY_CACHE_ID=shared\n",
            "RUN <<'SETUP' bash -e\n  echo ${KMONEY_CACHE_ID}\n  cargo build --release -p x\nSETUP\n"
        )),
        "a heredoc body belongs to the instruction that opened it"
    );
    assert!(
        !scopes_the_dependency_compile(
            "FROM base AS deps\nARG KMONEY_CACHE_ID=shared\nRUN cargo build --release -p x\n"
        ),
        "a declared-but-unreferenced ARG scopes nothing and must not satisfy this guard"
    );
    assert!(
        !scopes_the_dependency_compile(concat!(
            "FROM base AS deps\nARG KMONEY_CACHE_ID=shared\n",
            "RUN echo ${KMONEY_CACHE_ID}\nRUN cargo build --release -p x\n"
        )),
        "the reference must share an instruction with the compile, not merely the file"
    );
    assert!(
        !scopes_the_dependency_compile(concat!(
            "FROM base AS other\nARG KMONEY_CACHE_ID=shared\n",
            "FROM base AS deps\nRUN echo ${KMONEY_CACHE_ID} && cargo build --release -p x\n"
        )),
        "ARG is stage-scoped: a declaration in another stage arrives unconsumed and expands to \
         nothing, so the layer key stops varying while the file still reads correct"
    );
    assert!(
        !scopes_the_dependency_compile(concat!(
            "FROM base AS deps\nARG KMONEY_CACHE_ID=shared\n",
            "RUN <<'SETUP' bash -e\n  # scoped by ${KMONEY_CACHE_ID}\n  cargo build --release -p x\nSETUP\n"
        )),
        "a comment naming the argument is not an expansion of it"
    );
    assert!(
        !descends_from(
            &stages(concat!(
                "FROM base AS deps\nARG KMONEY_CACHE_ID=shared\n",
                "RUN echo ${KMONEY_CACHE_ID} && cargo build --release -p x\n",
                "FROM base AS build\nRUN cargo pgrx package\n"
            )),
            1,
            0
        ),
        "a package stage re-parented off the scoped stage must not read as descending from it"
    );

    // A cache mount at /work/target would MASK the layer beneath it, so the two cannot coexist:
    // reintroducing one would leave the dependency layer built, exported, restored -- and unused.
    assert!(
        !mounts_a_cache(&dockerfile),
        "the YugabyteDB image compiles into layers; a cache mount would shadow them and is also \
         builder-local, which is what made this compile unreachable by any CI cache"
    );
    assert!(
        mounts_a_cache(
            "FROM base AS deps\nRUN --mount=type=cache,target=/work/target cargo build --release\n"
        ),
        "the mount check must still see a mount that is actually there"
    );
    assert!(
        !mounts_a_cache("FROM base AS deps\nRUN true\n# the mounts were removed: --mount=type=cache\n"),
        "prose explaining why something is absent must not read as its presence"
    );

    let release = support::recipe_body(&support::just_dump(&root), "gate-pg-release");
    assert!(
        release.contains("export KMONEY_CACHE_ID=") && release.contains("/dev/urandom"),
        "gate-pg-release must DERIVE a scope no earlier build can have filled, not name one"
    );
}

/// Every YugabyteDB build whose bytes ship carries the release scope.
///
/// `artifact` is what the suites certify and `node` is what an orchestrator deploys; a release
/// build of either that silently reused a shared layer would be exactly the claim
/// `gate-pg-release` exists to refuse. `boundary-node` is a measurement artefact that never
/// reaches a deployable image, and `deps` only warms the cache, so neither is required to carry it.
#[test]
fn shipped_yugabytedb_builds_carry_the_release_scope() {
    let root = support::lane_root();
    let mut builds = Vec::new();
    for caller in
        ["Justfile", "kamu-money-pg/yb/node-image.sh", "kamu-money-pg/bench/run-bench-boundary-yb.sh"]
    {
        let source = support::read(root.join(caller));
        for (line, logical) in support::logical_lines(&source) {
            // A trailing space excludes `Dockerfile.pg15`, which builds the A/B reference.
            if !logical.trim_start().starts_with('#') && logical.contains("kamu-money-pg/yb/Dockerfile ") {
                builds.push((caller, line, logical));
            }
        }
    }

    // A comment must not swallow the command beneath it. Were it joined, the merged entry would
    // begin with `#`, the filter above would drop it, and a build written under a wrapped comment
    // would never be examined for the arguments it has to carry.
    let wrapped = support::logical_lines("# a comment ending in a backslash \\\ndocker build .");
    assert_eq!(wrapped.len(), 2, "a comment must not continue into the next line: {wrapped:?}");
    assert!(wrapped[1].1.contains("docker build"), "the command below a comment must survive");

    // A positive control. Routing these builds through a helper would leave nothing to inspect,
    // and that silence reads exactly like compliance.
    assert!(
        !builds.is_empty(),
        "no caller names a kamu-money-pg/yb/Dockerfile build any more, so this guard would pass \
         vacuously; keep the build and its scope together, or re-point the guard"
    );

    for (caller, line, logical) in &builds {
        let ships = ["--target artifact", "--target node"].iter().any(|target| logical.contains(target));
        if ships {
            assert!(
                logical.contains("--build-arg KMONEY_CACHE_ID"),
                "{caller}:{line} builds shipped YugabyteDB bytes without passing KMONEY_CACHE_ID, \
                 so gate-pg-release could not force it to compile from empty: {logical}"
            );
        }
    }
}

#[test]
fn every_lane_package_carries_both_license_texts() {
    let repository = support::repository_root();
    let canonical = [("LICENSE-MIT", "MIT License"), ("LICENSE-APACHE", "Apache License")];
    for (name, marker) in canonical {
        assert!(support::read(repository.join(name)).contains(marker), "{name} must contain {marker}");
    }

    let metadata = support::metadata();
    assert!(!metadata.workspace_packages().is_empty(), "lane metadata must contain packages");
    for package in metadata.workspace_packages() {
        let license =
            package.license.as_deref().unwrap_or_else(|| panic!("{} must declare a license", package.name));
        assert_eq!(license, "MIT OR Apache-2.0", "{} has an unexpected license", package.name);
        let directory =
            package.manifest_path.parent().expect("package manifest must have a parent").as_std_path();

        for (name, _) in canonical {
            let package_license = directory.join(name);
            assert!(package_license.is_file(), "{} must carry {name}", package.name);
            assert_eq!(
                support::read(package_license),
                support::read(repository.join(name)),
                "{}/{} must match the repository copy",
                package.name,
                name
            );
        }

        let manifest = support::manifest(package.manifest_path.as_std_path());
        if let Some(include) = manifest["package"].get("include").and_then(toml::Value::as_array) {
            assert!(
                include.iter().filter_map(toml::Value::as_str).any(|entry| entry.contains("LICENSE")),
                "{} uses package.include but omits license files",
                package.name
            );
        }
    }
}

#[test]
fn extension_dependency_is_registry_resolvable() {
    let metadata = support::metadata();
    let package = metadata
        .packages
        .iter()
        .find(|package| package.name == "kamu-money-pg")
        .expect("metadata must contain kamu-money-pg");
    let dependency = package
        .dependencies
        .iter()
        .find(|dependency| dependency.name == "kamu-money-core" && dependency.kind == DependencyKind::Normal)
        .expect("kamu-money-pg must depend on kamu-money-core");

    assert_ne!(dependency.req.to_string(), "*", "money-core needs a version requirement");
    assert!(
        dependency.path.is_none(),
        "money-core must not carry a manifest path; local tests inject a Cargo patch"
    );
    assert_eq!(package.publish.as_deref(), Some(&[][..]), "the extension lane must remain publish = false");
}

#[test]
fn control_file_matches_the_sql_extension_identity() {
    let path = support::lane_root().join("kamu-money-pg/kmoney.control");
    let control = support::read(&path);
    assert!(!control.contains("kmoney_t"), "control file must name the current kmoney type");
    assert_eq!(
        path.file_stem().and_then(|stem| stem.to_str()),
        Some("kmoney"),
        "the control-file stem is the CREATE EXTENSION name"
    );
}

#[test]
fn boundary_probe_cannot_enter_a_deployable_artifact() {
    let root = support::lane_root();
    let metadata = support::metadata();
    let package = metadata
        .packages
        .iter()
        .find(|package| package.name == "kamu-money-pg")
        .expect("metadata must contain kamu-money-pg");
    assert!(
        !package.features["default"].iter().any(|feature| feature == "boundary-probe"),
        "boundary-probe must not be a default feature"
    );
    assert!(package.features["boundary-probe"].is_empty(), "boundary-probe must remain a leaf feature");

    let dockerfile = support::read(root.join("kamu-money-pg/yb/Dockerfile"));
    let extra_features = dockerfile
        .lines()
        .find(|line| line.trim_start().starts_with("ARG EXTRA_FEATURES"))
        .expect("YugabyteDB Dockerfile must declare EXTRA_FEATURES");
    assert_eq!(extra_features.trim(), "ARG EXTRA_FEATURES=");
    assert!(
        dockerfile.contains("FROM node AS boundary-node"),
        "benchmark probe must use a separate Docker target"
    );
    assert!(
        !support::read(root.join("kamu-money-pg/yb/node-image.sh")).contains("boundary"),
        "deployable node builder must not mention the benchmark probe"
    );

    let release = support::recipe_body(&support::just_dump(&root), "gate-pg-release");
    assert!(release.contains("rs_noop"), "release proof must inspect shipped bytes for benchmark symbols");
}

#[test]
fn public_docs_do_not_call_the_scalar_a_store() {
    let root = support::lane_root();
    let mut offenders = Vec::new();
    for relative in support::tracked_files(None).into_iter().filter(|path| {
        path.extension().is_some_and(|extension| extension == "md")
            || path.extension().is_some_and(|extension| extension == "control")
    }) {
        let text = support::read(root.join(&relative));
        for (index, line) in text.lines().enumerate() {
            if ["OLTP store", "wallet store"].iter().any(|phrase| line.contains(phrase)) {
                offenders.push(format!("{}:{}: {}", relative.display(), index + 1, line.trim()));
            }
        }
    }
    assert!(
        offenders.is_empty(),
        "kmoney is an amount scalar, not an application store:\n{}",
        offenders.join("\n")
    );
}
