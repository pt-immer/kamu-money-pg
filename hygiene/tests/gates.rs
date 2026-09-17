mod support;

use serde_json::json;

#[test]
fn gates_compose_every_required_check() {
    let lane = support::lane_root();
    let lane_dump = support::just_dump(&lane);
    // EQUALITY, not containment. A subset leaves the unlisted dependencies free to be dropped
    // while this test goes on passing, which is how a developer gate becomes quietly weaker than
    // the required check it stands in for. Adding a check here is meant to fail until it is
    // named.
    let offline = support::recipe_dependencies(&lane_dump, "gate-offline");
    assert_eq!(
        offline,
        // `doc-gate-selftest` rather than `doc-pg`: it runs that recipe against a probed tree and
        // then against a clean one, so composing both would be a second full rustdoc pass.
        ["fmt-check", "lint", "deny", "doc-gate-selftest", "test-hygiene", "miri-payload"],
        "gate-offline no longer composes exactly the checks the lane gate promises"
    );

    // WHICH recipes CI must reach is the lane's own claim, so it is asserted here. The match is
    // on a `run:` VALUE, parsed rather than searched: a bare substring is satisfied by a
    // commented-out step, by a step whose `name:` merely mentions the recipe, and by any longer
    // recipe name sharing the prefix -- `just pg doc-pg` is a prefix of the `doc-pg-all` step
    // this change deletes. Both `- run:` and a `run:` under its own `name:` are the same step.
    let workflow = support::read(support::repository_root().join(".github/workflows/on-pr-synced.yml"));
    let commands: Vec<&str> = workflow
        .lines()
        .map(str::trim)
        .filter_map(|line| line.strip_prefix("- run: ").or_else(|| line.strip_prefix("run: ")))
        .map(str::trim)
        .collect();
    assert!(!commands.is_empty(), "no `run:` step parsed -- this guard would pass vacuously");
    for required in ["just pg test-hygiene", "just pg doc-gate-selftest"] {
        assert!(
            commands.contains(&required),
            "a CI job must run `{required}` as a whole step; no CI job runs `gate-offline`, so \
             composing it there is not what reaches a required check"
        );
    }
    assert!(
        support::recipe_dependencies(&lane_dump, "gate-pg").contains(&"gate-offline"),
        "gate-pg must compose gate-offline"
    );

    // What the ROOT gate schedules is a root claim, asserted where the scheduler is importable:
    // `tools/repo-policy/tests/gate.rs`. Reading it from here could only match recipe text, and
    // the stage list is no longer written there.
    let repository_dump = support::just_dump(&support::repository_root());
    assert!(
        support::recipe_dependencies(&repository_dump, "lint-all").contains(&"scrub"),
        "root lint-all must include the repository scrub"
    );
}

#[test]
fn release_gate_covers_one_immutable_deployable_artifact() {
    let dump = support::just_dump(&support::lane_root());
    let release = support::recipe_body(&dump, "gate-pg-release");
    for required in [
        "export KMONEY_USE_LOCAL_CORE=0",
        "just gate-pg",
        "just _yb-ab-ref",
        "node-image.sh",
        "YB_REQUIRE_BAKED=1",
        "run-yb-regress.sh",
        "rs_noop",
    ] {
        assert!(release.contains(required), "gate-pg-release must execute {required}");
    }

    // AND MUST NOT RUN THE DEPLOYMENT SUITES. Replication factor, tablet placement, read replicas
    // and dump/restore are YugabyteDB's behaviour: a kmoney payload is opaque bytes to DocDB, so
    // asserting that raft copies it, a split relocates it and a replica serves it tests Yugabyte,
    // and charges this gate hours to do it. They keep their recipes under `test-yb-deployment`.
    for operational in
        ["run-yb-cluster.sh", "run-yb-concurrent.sh", "run-yb-readreplica.sh", "run-yb-restore.sh"]
    {
        assert!(
            !release.contains(operational),
            "gate-pg-release runs {operational}, which proves YugabyteDB's behaviour rather than \
             the extension's; it belongs to `just pg test-yb-deployment`"
        );
    }

    // Dropped from the gate is not dropped from the repository: each stays runnable, and one
    // recipe still runs them together.
    let deployment = support::recipe_dependencies(&dump, "test-yb-deployment");
    for required in ["test-yb-cluster", "test-yb-readreplica", "test-yb-concurrent", "test-yb-restore"] {
        assert!(deployment.contains(&required), "test-yb-deployment must compose {required}");
    }
    assert!(
        !release.contains("just yb-ab"),
        "release gate must pass its resolved image to _yb-ab-ref, not resolve a mutable tag again"
    );
}

/// Every feature that gates code must be one the doc gate turns on.
///
/// `--document-private-items` decides what rustdoc KEEPS; the feature list decides what the
/// compiler hands it at all. A `#[cfg(feature = "x")]` block the recipe does not enable is not
/// documented, not link-checked, and not visibly absent.
///
/// `doc_gate.rs` proves the regions that exist today by planting a link in each. This
/// covers the one it cannot: a region added later.
///
/// Parsed, not scanned. A line-based reader misses an attribute rustfmt wrapped across lines,
/// harvests a feature merely NAMED in prose, and cannot see which clause a `not(...)` negates --
/// so `all(feature = "a", not(feature = "b"))` either demands `b` or, if the whole line is
/// vetoed, silently stops requiring `a`. The recipe's `--features` argument is likewise parsed
/// rather than searched, because a body carrying `--no-default-features` and
/// `--document-private-items` answers yes to a substring test for `doc`.
#[test]
fn the_doc_gate_compiles_every_feature_gated_block() {
    /// Features whose code must be compiled somewhere the doc gate can reach.
    ///
    /// A `not(...)` describes the build where its feature is OFF, so features inside one are not
    /// requirements. Everything else nested under `cfg`, `cfg_attr`, `all` or `any` is.
    fn required(meta: &syn::Meta, negated: bool, into: &mut Vec<String>) {
        match meta {
            syn::Meta::NameValue(value) if value.path.is_ident("feature") => {
                if let syn::Expr::Lit(syn::ExprLit { lit: syn::Lit::Str(name), .. }) = &value.value {
                    if !negated {
                        into.push(name.value());
                    }
                }
            }
            syn::Meta::List(list) => {
                let negated = negated || list.path.is_ident("not");
                let parser = syn::punctuated::Punctuated::<syn::Meta, syn::Token![,]>::parse_terminated;
                if let Ok(nested) = list.parse_args_with(parser) {
                    for item in &nested {
                        required(item, negated, into);
                    }
                }
            }
            _ => {}
        }
    }

    struct Gated(Vec<String>);
    impl syn::visit::Visit<'_> for Gated {
        fn visit_attribute(&mut self, attribute: &syn::Attribute) {
            if attribute.path().is_ident("cfg") || attribute.path().is_ident("cfg_attr") {
                required(&attribute.meta, false, &mut self.0);
            }
            syn::visit::visit_attribute(self, attribute);
        }
        fn visit_macro(&mut self, item: &syn::Macro) {
            // `cfg!(...)` selects code the same way the attribute does; its body is the same
            // grammar with the wrapper stripped.
            if item.path.is_ident("cfg") {
                if let Ok(meta) = item.parse_body::<syn::Meta>() {
                    required(&meta, false, &mut self.0);
                }
            }
            syn::visit::visit_macro(self, item);
        }
    }

    let mut visitor = Gated(Vec::new());
    for path in support::rust_sources_under(&support::lane_root().join("kamu-money-pg/src")) {
        let source = support::read(&path);
        let parsed = syn::parse_file(&source)
            .unwrap_or_else(|error| panic!("{} must parse as Rust: {error}", path.display()));
        syn::visit::Visit::visit_file(&mut visitor, &parsed);
    }
    let mut gated = visitor.0;
    gated.sort_unstable();
    gated.dedup();
    assert!(!gated.is_empty(), "no `cfg(feature = ...)` found -- this guard would pass vacuously");

    let body = support::recipe_body(&support::just_dump(&support::lane_root()), "doc-pg");
    let enabled: Vec<&str> = body
        .split_whitespace()
        .skip_while(|token| *token != "--features")
        .nth(1)
        .unwrap_or_else(|| panic!("doc-pg must pass --features; its body is:\n{body}"))
        .split(',')
        .collect();
    let missing: Vec<&String> = gated.iter().filter(|feature| !enabled.contains(&feature.as_str())).collect();
    assert!(
        missing.is_empty(),
        "doc-pg enables {enabled:?} and so never compiles the code behind {missing:?}. A pgrx \
         major among these cannot simply be added: they are mutually exclusive, so one rustdoc \
         run cannot cover them all and the gap is real."
    );
}

fn routes_scratch_through_run_root(body: &str) -> bool {
    const DEFAULT: &str = r#"RUN_ROOT="${KMONEY_RUN_ROOT:-kamu-money-pg/yb/out}""#;
    body.contains(DEFAULT)
        && body
            .lines()
            .filter(|line| !line.contains(DEFAULT))
            .all(|line| !line.contains("kamu-money-pg/yb/out"))
}

#[test]
fn artifact_recipes_use_the_configured_run_root() {
    let dump = support::just_dump(&support::lane_root());
    for recipe in ["yb-build", "yb-native", "_yb-ab-ref", "gate-pg-release"] {
        let body = support::recipe_body(&dump, recipe);
        assert!(
            routes_scratch_through_run_root(&body),
            "{recipe} must derive scratch paths from KMONEY_RUN_ROOT:\n{body}"
        );
    }

    let bad = r#"
        RUN_ROOT="${KMONEY_RUN_ROOT:-kamu-money-pg/yb/out}"
        docker build -o kamu-money-pg/yb/out .
    "#;
    assert!(!routes_scratch_through_run_root(bad), "positive control must reject a hard-coded path");
}

#[test]
fn structured_recipe_body_excludes_comments() {
    let dump = json!({
        "recipes": {
            "gate": {
                "body": [
                    ["#!/usr/bin/env bash"],
                    ["# run-yb-restore.sh explains the requirement"],
                    ["run-yb-regress.sh"]
                ]
            }
        }
    });
    let body = support::recipe_body(&dump, "gate");
    assert!(body.contains("run-yb-regress.sh"));
    assert!(
        !body.contains("run-yb-restore.sh"),
        "comment text must not satisfy an executable-composition assertion"
    );
}

fn captures_status_by_disabling_set_e(logical_line: &str) -> bool {
    logical_line.find("| tee").is_some_and(|pipe| logical_line[pipe..].contains("||"))
}

#[test]
fn gates_do_not_disable_set_e_while_capturing_output() {
    for bad in [r#"} 2>&1 | tee "$LOG" || rc=$?"#, r#"} 2>&1 | tee "$LOG" || true"#] {
        assert!(captures_status_by_disabling_set_e(bad));
    }
    for good in [r#"} 2>&1 | tee "$LOG""#, r#"rc=${PIPESTATUS[0]}"#, r#"command_that_may_fail || rc=$?"#] {
        assert!(!captures_status_by_disabling_set_e(good));
    }

    let root = support::lane_root();
    let mut files = support::tracked_files(Some("*.sh"));
    files.push("Justfile".into());
    let mut offenders = Vec::new();
    for relative in files {
        for (line, logical) in support::logical_lines(&support::read(root.join(&relative))) {
            if !logical.trim_start().starts_with('#') && captures_status_by_disabling_set_e(&logical) {
                offenders.push(format!("{}:{line}: {}", relative.display(), logical.trim()));
            }
        }
    }
    assert!(
        offenders.is_empty(),
        "a gate body in an `||` list runs with set -e disabled; capture PIPESTATUS after the pipeline:\n{}",
        offenders.join("\n")
    );
}
