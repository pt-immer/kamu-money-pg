//! Controls for the artifact selector the YugabyteDB image's copy-out step runs.
//!
//! The selector's whole job is to REFUSE, and a refusal that never fires is indistinguishable
//! from one that cannot. Inside a Docker build it cannot be falsified without a build argument
//! invented to break it, so the branches are exercised here instead: no Docker, no database.

use std::path::Path;

mod support;

use support::{Scratch, Shell, lane_root, run};

fn select(root: &Path, arguments: &[&str]) -> Shell {
    let mut argv = vec![root.to_str().expect("scratch paths are UTF-8")];
    argv.extend_from_slice(arguments);
    run("./kamu-money-pg/yb/exactly-one.sh", &argv, &lane_root(), &[])
}

/// Refusals are checked on three properties at once, because the image depends on all three and
/// the last is the easiest to lose. The copy-out step writes
/// `cp "$(one 'kmoney*.so')" /out/kmoney.so`, and a command substitution's non-zero status is
/// discarded in an argument position -- `set -e` never fires. So a refusal that still printed a
/// path would be copied anyway, and a build holding two majors' artifacts would ship one major's
/// library beside another major's install script: exactly the mismatched triplet the selector
/// exists to prevent, with every status and message check still green.
fn expect_refusal(outcome: &Shell, want_status: i32, want_text: &str) {
    assert_eq!(want_status, outcome.status, "status {}, wanted {want_status}", outcome.status);
    assert!(
        outcome.stdout.is_empty(),
        "refused but printed {:?} on stdout, which the image would then copy",
        outcome.stdout
    );
    assert!(
        outcome.stderr.contains(want_text),
        "the diagnostic did not mention {want_text:?}: {}",
        outcome.stderr
    );
}

/// Without this every assertion below would still pass against a selector that refuses
/// everything.
#[test]
fn exactly_one_match_is_printed() {
    let work = Scratch::new("exactly-one-accept");
    let library = work.write("release/kmoney-pg15/lib/kmoney.so", "");

    let outcome = select(work.path(), &["kmoney*.so"]);
    assert_eq!(0, outcome.status, "refused: {}", outcome.stderr);
    assert_eq!(format!("{}\n", library.display()), outcome.stdout);
}

#[test]
fn no_match_is_refused() {
    let work = Scratch::new("exactly-one-none");
    work.directory("release");

    expect_refusal(&select(work.path(), &["kmoney*.so"]), 1, "found 0");
}

/// A stale artifact from an earlier version, beside the current one.
#[test]
fn two_versions_of_the_install_script_are_refused() {
    let work = Scratch::new("exactly-one-two-versions");
    work.write("release/kmoney-pg15/share/kmoney--0.1.0.sql", "");
    work.write("release/kmoney-pg15/share/kmoney--0.2.0.sql", "");

    expect_refusal(&select(work.path(), &["kmoney--*.sql"]), 1, "found 2");
}

/// Two majors' staging directories, which is how a triplet could be assembled from two builds.
/// The refusal must also name every match, so the diagnostic identifies the build to remove.
#[test]
fn the_same_name_under_two_majors_is_refused_and_both_are_named() {
    let work = Scratch::new("exactly-one-two-majors");
    work.write("release/kmoney-pg15/lib/kmoney.so", "");
    work.write("release/kmoney-pg18/lib/kmoney.so", "");

    let outcome = select(work.path(), &["kmoney*.so"]);
    expect_refusal(&outcome, 1, "found 2");
    for major in ["kmoney-pg15", "kmoney-pg18"] {
        assert!(outcome.stderr.contains(major), "the refusal did not name {major}: {}", outcome.stderr);
    }
}

/// A usage refusal, distinguished from a wrong count by its status.
#[test]
fn a_root_that_does_not_exist_is_refused() {
    let work = Scratch::new("exactly-one-absent");

    expect_refusal(&select(&work.join("absent"), &["kmoney*.so"]), 2, "no directory");
}

#[test]
fn a_missing_pattern_argument_is_refused() {
    let work = Scratch::new("exactly-one-usage");
    work.directory("release");

    expect_refusal(&select(work.path(), &[]), 2, "usage");
}
