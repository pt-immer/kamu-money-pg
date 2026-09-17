//! Controls for the artifact resolver the YugabyteDB suites use.
//!
//! Mixed-build triplets and missing manifests, so the resolver cannot certify unverified bytes.
//! These name, version and hash checks need no Docker and no database.

use std::path::Path;

mod support;

use support::{Scratch, Shell, bash, lane_root};

const MANIFEST: &str = "ARTIFACT-MANIFEST.txt";

/// A complete, coherent, manifested triplet.
fn fixture(work: &Scratch, name: &str, version: &str) -> std::path::PathBuf {
    let directory = work.directory(name);
    work.write(format!("{name}/kmoney.so"), "ELF-not-really\n");
    work.write(format!("{name}/kmoney.control"), &format!("default_version = '{version}'\n"));
    work.write(format!("{name}/kmoney--{version}.sql"), "CREATE TYPE kmoney;\n");
    manifest(&directory, version);
    directory
}

/// `sha256sum`'s own format, which is what the resolver verifies with.
fn manifest(directory: &Path, version: &str) {
    let outcome = bash(
        directory,
        &format!("sha256sum kmoney.so kmoney.control kmoney--{version}.sql > {MANIFEST}"),
        &[],
    );
    assert_eq!(0, outcome.status, "the fixture manifest was not written: {}", outcome.stderr);
}

/// The resolver sets shell globals, so each case runs in its own shell. `YB_ART_VERIFIED` comes
/// back on stdout because the resolver's own stdout is not part of any contract here.
fn resolve(directory: &Path, allow_unverified: bool) -> (Shell, String) {
    let outcome = bash(
        &lane_root(),
        &format!(
            "source ./kamu-money-pg/yb/artifact.sh\n\
             set +e\n\
             yb_resolve_artifacts '{}' >/dev/null\n\
             rc=$?\n\
             printf 'VERIFIED=%s\\n' \"${{YB_ART_VERIFIED:-<unset>}}\"\n\
             exit \"$rc\"\n",
            directory.display()
        ),
        &[("YB_ART_ALLOW_UNVERIFIED", allow_unverified.then_some("1"))],
    );
    let verified = outcome
        .stdout
        .lines()
        .find_map(|line| line.strip_prefix("VERIFIED="))
        .unwrap_or("<absent>")
        .to_owned();
    (outcome, verified)
}

fn expect_accepted(directory: &Path, allow_unverified: bool, want_verified: &str) {
    let (outcome, verified) = resolve(directory, allow_unverified);
    assert_eq!(0, outcome.status, "REFUSED (exit {}): {}", outcome.status, outcome.stderr);
    assert_eq!(want_verified, verified, "accepted, but YB_ART_VERIFIED disagrees");
}

/// The refusal MESSAGE is asserted as well as the status, so each control reaches its intended
/// rule rather than any refusal that happens to fire.
fn expect_refused(directory: &Path, want: &str) {
    let (outcome, _) = resolve(directory, false);
    assert_ne!(0, outcome.status, "ACCEPTED, and should not have");
    assert!(
        outcome.stderr.contains(want),
        "refused for the wrong reason (wanted {want:?}): {}",
        outcome.stderr
    );
}

/// Without this, every refusal below could be the resolver refusing everything.
#[test]
fn a_coherent_manifested_triplet_resolves_and_is_marked_verified() {
    let work = Scratch::new("artifact-good");
    expect_accepted(&fixture(&work, "good", "0.1.0"), false, "yes");
}

/// Coherent names do not establish provenance; the manifest is mandatory. The override downgrades
/// it deliberately and says so in the flag, rather than resolving silently.
#[test]
fn a_triplet_with_no_manifest_is_refused_and_the_override_downgrades_rather_than_hides() {
    let work = Scratch::new("artifact-nomanifest");
    let directory = fixture(&work, "nomanifest", "0.1.0");
    std::fs::remove_file(directory.join(MANIFEST)).expect("the manifest is removable");

    expect_refused(&directory, "have no provenance");
    expect_accepted(&directory, true, "no");
}

#[test]
fn one_changed_byte_fails_the_manifest() {
    let work = Scratch::new("artifact-tampered");
    let directory = fixture(&work, "tampered", "0.1.0");
    work.write("tampered/kmoney.so", "ELF-substituted\n");

    expect_refused(&directory, "MANIFEST MISMATCH");
}

/// `CREATE EXTENSION` reads `default_version` to decide which script to run, so a disagreement
/// means the script that runs is not the script anything checked.
#[test]
fn a_control_file_disagreeing_with_the_script_filename_is_refused() {
    let work = Scratch::new("artifact-skew");
    let directory = fixture(&work, "skew", "0.1.0");
    work.write("skew/kmoney.control", "default_version = '0.2.0'\n");
    manifest(&directory, "0.1.0");

    expect_refused(&directory, "INCOHERENT TRIPLET");
}

#[test]
fn two_install_scripts_are_ambiguous_and_the_harness_will_not_choose() {
    let work = Scratch::new("artifact-ambiguous");
    let directory = fixture(&work, "ambiguous", "0.1.0");
    work.write("ambiguous/kmoney--0.2.0.sql", "CREATE TYPE kmoney;\n");

    expect_refused(&directory, "install scripts, so the version is ambiguous");
}

#[test]
fn every_missing_member_of_the_triplet_is_named() {
    for (label, removed, named) in [
        ("noso", "kmoney.so", "kmoney.so"),
        ("noctl", "kmoney.control", "kmoney.control"),
        ("nosql", "kmoney--0.1.0.sql", "kmoney--<version>.sql"),
    ] {
        let work = Scratch::new(&format!("artifact-{label}"));
        let directory = fixture(&work, label, "0.1.0");
        std::fs::remove_file(directory.join(removed)).expect("the fixture member is removable");

        expect_refused(&directory, named);
    }
}

#[test]
fn a_directory_that_does_not_exist_is_refused() {
    let work = Scratch::new("artifact-absent");

    expect_refused(&work.join("absent"), "does not exist");
}

/// The ORIGINAL defect: a recursive search that could reach into a run's subdirectory. `out/`
/// deliberately accumulates `ref/` and one directory per run, so a valid triplet one level down
/// must be invisible -- or the resolver is back to certifying whichever file the filesystem
/// handed back first.
#[test]
fn a_valid_triplet_in_a_subdirectory_is_not_found() {
    let work = Scratch::new("artifact-nested");
    let nested = work.directory("nested");
    fixture(&work, "nested/ref", "0.1.0");

    expect_refused(&nested, "missing under");
}
