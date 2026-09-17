//! Mutual-exclusion, re-entrancy and lifecycle controls for `workspace-lock.sh`.
//!
//! Every case runs against a fixture lock directory, so these contend only with each other and
//! never with a developer's real run. No Docker and no database.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

mod support;

use support::{Scratch, Shell, bash, lane_root};

/// The library under test, addressed absolutely: the holder scripts run from their own directory.
fn locklib() -> PathBuf {
    lane_root().join("kamu-money-pg/yb/workspace-lock.sh")
}

/// Take the lock in a fresh shell, the way every caller does.
fn acquire(lock_directory: &Path, library: &Path, label: &str, fd: Option<&str>) -> Shell {
    bash(
        &lane_root(),
        &format!("source '{}'; workspace_lock '{label}'", library.display()),
        &[
            ("KMONEY_LOCK_DIR", lock_directory.to_str()),
            ("KMONEY_WORKSPACE_LOCK_FD", fd),
            ("KMONEY_RUN_ROOT", None),
        ],
    )
}

/// Kills the whole process group on the way out, so a failing assertion cannot leave a holder
/// sitting on a lock for the rest of the run.
struct Group(String);

impl Drop for Group {
    fn drop(&mut self) {
        let _ = Command::new("kill").args(["--", &format!("-{}", self.0)]).status();
    }
}

fn wait_for(path: &Path) -> bool {
    for _ in 0..100 {
        if path.exists() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    false
}

/// Start a detached holder and return its pid, which under `setsid` is also its process GROUP id.
///
/// `setsid` so the holder leads its own group and the group kill below has something to aim at:
/// without job control -- and a test binary is not interactive -- a plain background start would
/// leave it in this process's group, where a group kill would take the test runner down with it.
/// The script records its own pid because the spawned child here is `setsid`, not the holder.
fn start_holder(work: &Scratch, lock_directory: &Path, library: &Path, body: &str) -> (Group, String) {
    let script = work.write_program(
        "holder.sh",
        &format!(
            "#!/usr/bin/env bash\n\
             set -euo pipefail\n\
             source '{}'\n\
             workspace_lock 'selftest-holder' || exit 1\n\
             echo $$ > '{}'\n\
             {body}\n\
             touch '{}'\n\
             sleep 30\n",
            library.display(),
            work.join("pgid").display(),
            work.join("ready").display(),
        ),
    );

    Command::new("setsid")
        .arg(&script)
        .current_dir(lane_root())
        .env("KMONEY_LOCK_DIR", lock_directory)
        .env_remove("KMONEY_WORKSPACE_LOCK_FD")
        .env_remove("KMONEY_RUN_ROOT")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("setsid must run");

    assert!(wait_for(&work.join("ready")), "the first caller never acquired the lock at all");
    let pid = std::fs::read_to_string(work.join("pgid")).expect("the holder records its pid");
    let pid = pid.trim().to_owned();
    assert!(pid.chars().all(|c| c.is_ascii_digit()) && !pid.is_empty(), "the holder pid is not a pid");
    (Group(pid.clone()), pid)
}

#[test]
fn a_second_caller_is_refused_and_told_what_holds_it() {
    let work = Scratch::new("lock-exclusion");
    let lock_directory = work.directory("lockdir");
    let (_group, pid) = start_holder(&work, &lock_directory, &locklib(), "");

    let outcome = acquire(&lock_directory, &locklib(), "selftest-second", None);
    assert_ne!(0, outcome.status, "a SECOND caller acquired a lock the first one is holding");
    assert!(
        outcome.stderr.contains("REFUSING"),
        "it failed, but not with a refusal a human can act on: {}",
        outcome.stderr
    );
    // Naming the holder is what makes the refusal actionable rather than a wall to wait at.
    assert!(
        outcome.stderr.contains("selftest-holder") && outcome.stderr.contains(&pid),
        "the refusal did not identify the holder: {}",
        outcome.stderr
    );
}

/// `release-check` children inherit the real descriptor and must not deadlock on their parent.
#[test]
fn a_real_descendant_of_the_holder_proceeds_rather_than_deadlocking() {
    let work = Scratch::new("lock-reentrant");
    let lock_directory = work.directory("lockdir");
    let library = locklib();
    let child = work.join("child.rc");
    let (_group, _pid) = start_holder(
        &work,
        &lock_directory,
        &library,
        &format!(
            "rc=0\n\
             bash -c \"source '{}'; workspace_lock 'selftest-real-child'\" >/dev/null 2>&1 || rc=$?\n\
             echo \"$rc\" > '{}'\n",
            library.display(),
            child.display(),
        ),
    );

    assert!(wait_for(&child), "the holder never reported its child's result");
    assert_eq!(
        "0",
        std::fs::read_to_string(&child).expect("the child result is readable").trim(),
        "an actual child of the holder was refused, so release-check would block on its own suites"
    );
}

/// An unrelated process cannot claim inheritance through an environment variable alone: the
/// descriptor is checked, not the claim.
#[test]
fn a_forged_descriptor_is_refused_whether_or_not_it_is_open() {
    let work = Scratch::new("lock-forged");
    let lock_directory = work.directory("lockdir");
    let (_group, _pid) = start_holder(&work, &lock_directory, &locklib(), "");

    let closed = acquire(&lock_directory, &locklib(), "selftest-forged", Some("1"));
    assert_ne!(0, closed.status, "a process with no lock acquired one by setting the variable by hand");
    assert!(
        closed.stderr.contains("not an open handle"),
        "the forged variable was refused for some other reason: {}",
        closed.stderr
    );

    // A descriptor that IS open, on the wrong file. This catches a check that only asks "is fd N
    // open?" -- fd 2 always is.
    let elsewhere = acquire(&lock_directory, &locklib(), "selftest-wrongfd", Some("2"));
    assert_ne!(
        0, elsewhere.status,
        "an open descriptor on an unrelated file was accepted as the workspace lock"
    );
}

/// Every public way into the shared paths. Private `_yb-ab-ref` is included because
/// `release-check` calls it directly, so it is an entry point in practice.
const ENTRY_POINTS: [&str; 18] = [
    "just yb-build",
    "just yb-native",
    "just yb-ab",
    "just _yb-ab-ref sha256:0000000000000000000000000000000000000000000000000000000000000000",
    "just yb-selftest",
    "./kamu-money-pg/yb/run-yb.sh",
    "./kamu-money-pg/yb/run-yb-regress.sh",
    "./kamu-money-pg/yb/run-yb-cluster.sh",
    "./kamu-money-pg/yb/run-yb-concurrent.sh",
    "./kamu-money-pg/yb/run-yb-readreplica.sh",
    "./kamu-money-pg/yb/run-yb-restore.sh",
    "./kamu-money-pg/yb/run-yb-resilience.sh",
    "./kamu-money-pg/yb/run-yb-soak.sh",
    "./kamu-money-pg/yb/run-yb-bench.sh",
    "./kamu-money-pg/bench/run-bench-pg.sh",
    "./kamu-money-pg/bench/run-bench-boundary.sh",
    "./kamu-money-pg/bench/run-bench-sql-yb.sh",
    "./kamu-money-pg/bench/run-bench-boundary-yb.sh",
];

/// Names, sizes and mtimes -- enough to see a write, cheap enough to run per entry point even
/// when the tree holds a release log and a 20 MB library.
fn snapshot(root: &Path) -> String {
    bash(root, "find . -type f -printf '%p %s %T@\\n' 2>/dev/null | sort", &[]).stdout
}

/// Every writer must refuse BEFORE changing shared state. Refusing afterwards is a run that has
/// already overwritten what another run was mid-way through reading.
#[test]
fn every_public_entry_point_refuses_and_touches_nothing_first() {
    let work = Scratch::new("lock-entries");
    let lock_directory = work.directory("lockdir");
    let shared = work.directory("shared");
    let (_group, _pid) = start_holder(&work, &lock_directory, &locklib(), "");

    // Stubs record any accidental call without starting expensive work.
    let stubs = work.directory("bin");
    let calls = work.join("tool.calls");
    for tool in ["docker", "cargo"] {
        work.write_program(
            format!("bin/{tool}"),
            &format!("#!/bin/sh\nprintf '{tool} %s\\n' \"$*\" >> '{}'\nexit 1\n", calls.display()),
        );
    }

    // A canary, so the snapshot has something to notice even though the fixture starts empty.
    work.write("shared/.workspace-lock-selftest-canary", "written by a control; safe to delete\n");
    let mut before = snapshot(&shared);

    let path = format!("{}:{}", stubs.display(), std::env::var("PATH").unwrap_or_default());
    for entry in ENTRY_POINTS {
        let outcome = bash(
            &lane_root(),
            &format!("timeout 60 bash -c {}", shell_quote(entry)),
            &[
                ("PATH", Some(&path)),
                ("KMONEY_LOCK_DIR", lock_directory.to_str()),
                ("KMONEY_RUN_ROOT", shared.to_str()),
                ("KMONEY_WORKSPACE_LOCK_FD", None),
            ],
        );
        assert_ne!(0, outcome.status, "{entry} RAN TO COMPLETION while another run held the workspace lock");
        // The status alone is satisfied by a typo, a missing `just`, or a syntax error -- all of
        // which would leave an entry point uncovered while this control stayed green. The
        // refusal text is what ties the status to the lock.
        assert!(
            outcome.stderr.contains("workspace-lock: REFUSING"),
            "{entry} failed, but not because of the lock: {}",
            outcome.stderr
        );
        let after = snapshot(&shared);
        assert_eq!(before, after, "{entry} changed shared state before being refused");
        before = after;
    }

    assert!(
        !calls.exists() || std::fs::read_to_string(&calls).unwrap_or_default().trim().is_empty(),
        "an entry point reached docker or cargo despite the lock: {}",
        std::fs::read_to_string(&calls).unwrap_or_default()
    );
}

fn shell_quote(text: &str) -> String {
    format!("'{}'", text.replace('\'', r"'\''"))
}

/// The kernel releases the lock when the last inherited descriptor closes. Killing only the
/// parent must not free it while a child still writes; killing the whole group must free it.
#[test]
fn the_lock_outlives_the_holder_but_not_its_process_group() {
    let work = Scratch::new("lock-lifecycle");
    let lock_directory = work.directory("lockdir");
    let library = locklib();
    // A descendant holding the inherited descriptor open, which is what makes the two kills
    // distinguishable at all.
    let (group, pid) = start_holder(&work, &lock_directory, &library, "sleep 30 &");

    let _ = Command::new("kill").arg(&pid).status();
    for _ in 0..100 {
        if !Command::new("kill").args(["-0", &pid]).status().expect("kill -0 must run").success() {
            break;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    assert_ne!(
        0,
        acquire(&lock_directory, &library, "selftest-orphan", None).status,
        "the lock freed while a child of the dead holder was still running and still writing"
    );

    // The whole process group, which is what a Ctrl-C or a runner teardown sends.
    drop(group);
    let mut freed = false;
    for _ in 0..100 {
        if acquire(&lock_directory, &library, "selftest-probe", None).status == 0 {
            freed = true;
            break;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    assert!(freed, "the lock survived its entire process group, so a killed run wedges the checkout");
}

/// A unique explicit run root gives one run a private artifact tree, so it shares nothing and
/// must not be refused by the unrelated default-root lock.
///
/// The library is COPIED into the fixture tree, because the default lock path resolves from the
/// file's own location -- a control reading the real default would contend with a developer's run.
#[test]
fn an_explicit_run_root_does_not_contend_with_the_default_root() {
    let work = Scratch::new("lock-isolated");
    let isolated = work.directory("isolated");
    let library = isolated.join("workspace-lock.sh");
    std::fs::copy(locklib(), &library).expect("the lock library is copyable");

    let script = work.write_program(
        "isolated/holder.sh",
        &format!(
            "#!/usr/bin/env bash\n\
             set -euo pipefail\n\
             source '{}'\n\
             workspace_lock 'isolated-control-holder'\n\
             echo $$ > '{}'\n\
             touch '{}'\n\
             sleep 30\n",
            library.display(),
            work.join("isolated/pgid").display(),
            work.join("isolated/ready").display(),
        ),
    );
    Command::new("setsid")
        .arg(&script)
        .current_dir(&isolated)
        .env_remove("KMONEY_RUN_ROOT")
        .env_remove("KMONEY_LOCK_DIR")
        .env_remove("KMONEY_WORKSPACE_LOCK_FD")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("setsid must run");
    assert!(
        wait_for(&work.join("isolated/ready")),
        "the isolated-root control holder never acquired its default lock"
    );
    let pid = std::fs::read_to_string(work.join("isolated/pgid")).expect("the holder records its pid");
    let _group = Group(pid.trim().to_owned());

    let private = bash(
        &lane_root(),
        &format!("source '{}'; workspace_lock 'private-run'", library.display()),
        &[
            ("KMONEY_RUN_ROOT", work.join("private-run").to_str()),
            ("KMONEY_LOCK_DIR", None),
            ("KMONEY_WORKSPACE_LOCK_FD", None),
        ],
    );
    assert_eq!(
        0, private.status,
        "an explicit run root was refused by the unrelated default-root lock: {}",
        private.stderr
    );
}
