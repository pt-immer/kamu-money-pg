mod support;

use serde_json::json;
use support::{Scratch, lane_root, run};

#[test]
fn core_is_locked_to_crates_io_without_a_path_patch() {
    let lock = support::manifest(lane_root().join("Cargo.lock"));
    let core: Vec<_> = lock["package"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|p| p["name"].as_str() == Some("kamu-money-core"))
        .collect();
    assert_eq!(core.len(), 1);
    assert_eq!(core[0]["source"].as_str(), Some("registry+https://github.com/rust-lang/crates.io-index"));
    assert_eq!(core[0]["checksum"].as_str().unwrap().len(), 64);
    for file in ["Cargo.toml", ".cargo/config.toml"] {
        let manifest = support::manifest(lane_root().join(file));
        assert!(
            manifest
                .get("patch")
                .and_then(|p| p.get("crates-io"))
                .and_then(|p| p.get("kamu-money-core"))
                .is_none()
        );
    }
}

#[test]
fn resolver_refuses_wrong_sources_missing_tests_and_cargo_failures() {
    let scratch = Scratch::new("core-registry");
    let core = scratch.directory("core");
    for file in ["Cargo.toml", "tests/pg_native_column.rs", "tests/yugabyte_roundtrip.rs"] {
        scratch.write(format!("core/{file}"), "");
    }
    scratch.write_program(
        "bin/cargo",
        r#"#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == *"--locked"* ]] || exit 91
cat "$METADATA"
"#,
    );
    let metadata = scratch.join("metadata.json");
    let path = format!("{}:{}", scratch.join("bin").display(), std::env::var("PATH").unwrap());
    let invoke = || {
        run(
            "bash",
            &["scripts/resolve-core-manifest.sh"],
            &lane_root(),
            &[("PATH", Some(&path)), ("METADATA", Some(metadata.to_str().unwrap()))],
        )
    };
    let package = |source| {
        json!({"name":"kamu-money-core", "version":"0.2.0",
        "manifest_path":core.join("Cargo.toml"), "source":source})
    };
    let registry = "registry+https://github.com/rust-lang/crates.io-index";
    for source in [Some(registry), None, Some("git+https://example.invalid/core")] {
        scratch.write("metadata.json", &json!({"packages":[package(source)]}).to_string());
        let result = invoke();
        assert_eq!(result.succeeded(), source == Some(registry), "{}", result.output());
    }
    for packages in [json!([]), json!([package(Some(registry)), package(Some(registry))])] {
        scratch.write("metadata.json", &json!({"packages":packages}).to_string());
        assert!(!invoke().succeeded());
    }
    scratch.write("metadata.json", &json!({"packages":[package(Some(registry))]}).to_string());
    std::fs::remove_file(core.join("tests/pg_native_column.rs")).unwrap();
    let missing = invoke();
    assert!(!missing.succeeded());
    assert!(missing.output().contains("missing tests/pg_native_column.rs"));
    scratch.write_program("bin/cargo", "#!/bin/sh\necho 'lock file needs to be updated' >&2\nexit 101\n");
    let stale = invoke();
    assert!(!stale.succeeded());
    assert!(stale.output().contains("lock file needs to be updated"));
}

#[test]
fn pgrx_cargo_proxy_locks_resolution_before_forwarding_arguments() {
    let scratch = Scratch::new("cargo-locked");
    let cargo = scratch.write_program("cargo", "#!/bin/sh\nprintf '%s\\n' \"$@\"\n");
    for subcommand in ["build", "check", "metadata", "test", "rustc"] {
        let result = run(
            "bash",
            &["scripts/locked/cargo", subcommand, "--", "argument"],
            &lane_root(),
            &[("KMONEY_REAL_CARGO", Some(cargo.to_str().unwrap()))],
        );
        assert!(result.succeeded(), "{}", result.output());
        assert_eq!(result.stdout, format!("{subcommand}\n--locked\n--\nargument\n"));
    }
}
