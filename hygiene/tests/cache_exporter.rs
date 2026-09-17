//! Controls for the buildx cache-export pre-flight check.
//!
//! The check turns a mid-build BuildKit driver error into a diagnostic with the remedy. Its first
//! version did the opposite: a `DRIVER="$(docker buildx inspect | awk ...)"` assignment under
//! `set -euo pipefail` aborted AT THE ASSIGNMENT when the probe failed, so every diagnostic below
//! it was unreachable and the caller saw a bare non-zero exit. That failed a green YugabyteDB CI
//! job whose builder was merely not answering yet, while four PostgreSQL jobs on the same commit
//! passed.
//!
//! So the property under test is not only "does it refuse the wrong driver" but "what does it do
//! when it CANNOT TELL". `docker` is stubbed, so none of this needs a daemon or a builder.

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::process::Command;

mod support;

struct Outcome {
    status: i32,
    stderr: String,
}

/// Install a `docker` that runs `body` and exits `code`, then invoke the check the way its callers
/// do — under `set -euo pipefail`, which is what made the original failure silent.
fn with_docker(label: &str, body: &str, code: i32) -> Outcome {
    let lane = support::repository_root().join("extensions/money-pg");
    let work = std::env::temp_dir().join(format!("kmoney-cache-exporter-{label}"));
    let bin = work.join("bin");
    let _ = fs::remove_dir_all(&work);
    fs::create_dir_all(&bin).expect("stub directory is creatable");

    let stub = bin.join("docker");
    fs::write(&stub, format!("#!/bin/sh\n{body}\nexit {code}\n")).expect("stub is writable");
    fs::set_permissions(&stub, fs::Permissions::from_mode(0o755)).expect("stub is executable");

    let inherited = std::env::var("PATH").unwrap_or_default();
    let output = Command::new("bash")
        .args(["-c", "set -euo pipefail; bash ./scripts/require-cache-exporter.sh selftest"])
        .current_dir(&lane)
        .env("PATH", format!("{}:{inherited}", bin.display()))
        .output()
        .expect("bash runs");

    let _ = fs::remove_dir_all(&work);
    Outcome {
        status: output.status.code().unwrap_or(-1),
        stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
    }
}

fn expect(label: &str, want_status: i32, want_text: &str, body: &str, code: i32) {
    let outcome = with_docker(label, body, code);
    assert_eq!(
        want_status, outcome.status,
        "{label}: exit {} wanted {want_status}: {}",
        outcome.status, outcome.stderr
    );
    assert!(
        want_text.is_empty() || outcome.stderr.contains(want_text),
        "{label}: stderr did not mention {want_text:?}: {}",
        outcome.stderr
    );
}

/// A probe that cannot answer must not be the thing that fails the build, and it must report what
/// it saw rather than exiting mute.
#[test]
fn an_unreachable_daemon_proceeds_and_repeats_what_the_probe_said() {
    let body = r#"echo "cannot connect to the Docker daemon" >&2"#;
    expect("unreachable-proceeds", 0, "could not inspect", body, 1);
    expect("unreachable-repeats", 0, "cannot connect", body, 1);
}

#[test]
fn output_naming_no_driver_proceeds() {
    expect("no-driver", 0, "names no driver", r#"echo "Name: builder""#, 0);
}

#[test]
fn the_stock_docker_driver_is_refused_with_the_remedy() {
    expect("stock-driver", 2, "docker buildx create", r#"printf "Name: default\nDriver: docker\n""#, 0);
}

#[test]
fn a_driver_that_can_export_a_cache_passes_silently() {
    for driver in ["docker-container", "kubernetes", "remote"] {
        expect(driver, 0, "", &format!(r#"printf "Name: b\nDriver: {driver}\n""#), 0);
    }
}
