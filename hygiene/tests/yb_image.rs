//! Positive and negative controls for `yb-image.sh`, the gate that decides whether a YugabyteDB
//! image is one anybody validated.
//!
//! The fixture is a local `FROM scratch` image, so this needs neither network access nor a
//! YugabyteDB image; it returns an image ID rather than a RepoDigest, which is the branch a
//! locally built image takes anyway.
//!
//! `#[ignore]` because it needs a Docker daemon, and `gate-offline` composes `test-hygiene`. The
//! `yb-image-selftest` recipe passes `--run-ignored all`.

use std::path::Path;

mod support;

use support::{Scratch, Shell, bash, lane_root, run};

const TAG: &str = "kmoney-yb-image-selftest:probe";

/// Removes the fixture image however the test ends.
struct Image;

impl Drop for Image {
    fn drop(&mut self) {
        let _ = bash(&lane_root(), &format!("docker rmi -f {TAG} >/dev/null 2>&1"), &[]);
    }
}

/// stdout and stderr stay APART, because which stream a message lands on is itself part of the
/// contract: every caller captures stdout as the image identity.
fn resolve(pinfile: &Path, allow_drift: bool, allow_unpinned: bool) -> Shell {
    run(
        "./kamu-money-pg/yb/yb-image.sh",
        &[TAG],
        &lane_root(),
        &[
            ("YB_PINFILE", pinfile.to_str()),
            ("YB_ALLOW_DRIFT", allow_drift.then_some("1")),
            ("YB_ALLOW_UNPINNED", allow_unpinned.then_some("1")),
            ("YB_PULL", None),
        ],
    )
}

#[test]
#[ignore = "builds a fixture image, so it needs a Docker daemon"]
fn every_refusal_path_bites_and_the_two_overrides_stay_distinct() {
    let work = Scratch::new("yb-image");
    let lane = lane_root();
    work.write("Dockerfile", "FROM scratch\n");

    let built = bash(&lane, &format!("docker build -q -t {TAG} '{}'", work.path().display()), &[]);
    assert_eq!(0, built.status, "the fixture image did not build: {}", built.stderr);
    let _image = Image;

    let inspected = bash(&lane, &format!("docker image inspect --format '{{{{ .Id }}}}' {TAG}"), &[]);
    assert_eq!(0, inspected.status, "the fixture image has no id: {}", inspected.stderr);
    let id = inspected.stdout.trim().to_owned();

    let pinfile = work.join("pin");
    let pin = |digest: &str| work.write("pin", &format!("{TAG}\t{digest}\n"));

    let accepted = |outcome: &Shell, what: &str| {
        assert_eq!(0, outcome.status, "{what} -- REFUSED: {}", outcome.stderr);
        assert_eq!(id, outcome.stdout.trim(), "{what} -- accepted but printed another identity");
    };
    // A refusal that still printed an identity would be consumed by the caller's command
    // substitution regardless of the status.
    let refused = |outcome: &Shell, want: &str, what: &str| {
        assert_ne!(0, outcome.status, "{what} -- it ACCEPTED the image");
        assert!(
            outcome.stderr.contains(want),
            "{what} -- refused, but not for the stated reason: {}",
            outcome.stderr
        );
        assert!(
            outcome.stdout.trim().is_empty(),
            "{what} -- refused but still printed an identity: {}",
            outcome.stdout
        );
    };

    // The accepting path, so the refusals below are not vacuous.
    pin(&id);
    accepted(&resolve(&pinfile, false, false), "a tag at its pinned digest");

    // Moved off the pin. Each override applies only to its own condition.
    pin("sha256:0000000000000000000000000000000000000000000000000000000000000000");
    refused(&resolve(&pinfile, false, false), "moved off the validated digest", "a moved tag");
    accepted(&resolve(&pinfile, true, false), "YB_ALLOW_DRIFT=1 adopts a moved tag");
    refused(
        &resolve(&pinfile, false, true),
        "moved off the validated digest",
        "YB_ALLOW_UNPINNED=1 does not rescue a moved pin",
    );

    // Never pinned at all -- the fail-open bug this gate exists to close.
    work.write("pin", "some-other-tag:1.0\tsha256:dead\n");
    refused(&resolve(&pinfile, false, false), "not recorded in the pin file", "an unrecorded tag");
    accepted(&resolve(&pinfile, false, true), "YB_ALLOW_UNPINNED=1 adopts an unrecorded tag");
    refused(
        &resolve(&pinfile, true, false),
        "not recorded in the pin file",
        "YB_ALLOW_DRIFT=1 does not rescue an unrecorded tag",
    );

    // No pin file at all, which must not read as permission.
    let absent = work.join("does-not-exist");
    refused(&resolve(&absent, false, false), "no pin file at all", "a missing pin file");
    accepted(&resolve(&absent, false, true), "YB_ALLOW_UNPINNED=1 bootstraps with no pin file");
}
