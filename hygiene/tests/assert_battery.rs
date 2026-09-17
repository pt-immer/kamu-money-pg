//! Negative controls for the battery oracle.
//!
//! `assert-battery.sh` is what makes `yb-ab`'s equality mean anything, so every assertion must
//! reject a corresponding mutation. The mutations are DERIVED from `assert-battery.sh --list`, so
//! an assertion added there is negatively controlled by construction rather than by remembering:
//! the version that hard-coded its own mutations covered 6 of 10 assertions and still reported
//! that every assertion still bites.
//!
//! Each mutation deletes every matching line, and the oracle must reject it for that assertion's
//! own reason -- so a broad pattern that deletes the whole file fails this control too.
//!
//! `#[ignore]`, and `KMONEY_BATTERY_OUTPUT` names a real battery output. The `yb-selftest` recipe
//! takes the workspace lock, resolves the default path and skips when there is none; a test that
//! decided that for itself would pass when handed nothing.

use std::path::{Path, PathBuf};

mod support;

use support::{Scratch, Shell, bash, lane_root, read, run};

/// Derived controls cover each present assertion; this floor also detects removal. Lowering it is
/// a deliberate act that should be argued for in the diff.
const MINIMUM_ASSERTIONS: usize = 20;

const ASSERT: &str = "./kamu-money-pg/yb/assert-battery.sh";

fn battery_output() -> PathBuf {
    let named = std::env::var("KMONEY_BATTERY_OUTPUT")
        .expect("KMONEY_BATTERY_OUTPUT must name a battery output; run `just pg yb-selftest`");
    // The lane's own paths are written relative to the lane root, which is not a test process's
    // working directory.
    let named = PathBuf::from(named);
    let path = if named.is_absolute() { named } else { lane_root().join(named) };
    assert!(
        path.metadata().is_ok_and(|data| data.len() > 0),
        "{} is missing or empty, so these controls would probe nothing",
        path.display()
    );
    path
}

fn assert_battery(file: &Path, label: &str, status: Option<&str>) -> Shell {
    let mut arguments = vec![file.to_str().expect("paths are UTF-8"), label];
    if let Some(status) = status {
        arguments.push(status);
    }
    run(ASSERT, &arguments, &lane_root(), &[])
}

/// The oracle must FAIL, and its message must name the expected reason. A case failing for the
/// WRONG reason is a broken control -- counting it as "worked" is how a control set rots while
/// still looking green.
fn expect_rejected(file: &Path, label: &str, status: &str, want: &str) {
    let outcome = assert_battery(file, label, Some(status));
    assert_ne!(0, outcome.status, "[{label}] PASSED but should have failed");
    assert!(
        outcome.output().contains(want),
        "[{label}] failed for the WRONG reason; wanted {want:?}, got: {}",
        outcome.output()
    );
}

/// One row of `--list`: `MODE %%% PATTERN %%% EXPECTED %%% DESCRIPTION`.
struct Assertion {
    regex: bool,
    pattern: String,
    description: String,
}

fn assertion_table() -> Vec<Assertion> {
    let listed = run(ASSERT, &["--list"], &lane_root(), &[]);
    assert_eq!(0, listed.status, "the assertion table is unreadable: {}", listed.stderr);

    let table: Vec<Assertion> = listed
        .stdout
        .lines()
        .filter(|row| !row.trim().is_empty())
        .map(|row| {
            let fields: Vec<&str> = row.split("%%%").collect();
            assert!(fields.len() >= 4, "malformed assertion row: {row}");
            Assertion {
                regex: fields[0] == "E",
                pattern: fields[1].to_owned(),
                description: fields[3].to_owned(),
            }
        })
        .collect();
    assert!(
        table.len() >= MINIMUM_ASSERTIONS,
        "the assertion table has shrunk to {} (floor is {MINIMUM_ASSERTIONS}) -- an assertion was removed",
        table.len()
    );
    table
}

/// Without this, every rejection below could be an oracle that refuses everything.
#[test]
#[ignore = "needs a battery output; run `just pg yb-selftest`"]
fn a_real_battery_output_passes_every_assertion() {
    let outcome = assert_battery(&battery_output(), "selftest-positive", Some("0"));
    assert_eq!(0, outcome.status, "a real battery output was REJECTED: {}", outcome.output());
}

#[test]
#[ignore = "needs a battery output; run `just pg yb-selftest`"]
fn structural_corruptions_are_rejected() {
    let source = battery_output();
    let text = read(&source);
    let work = Scratch::new("battery-structural");

    expect_rejected(&work.write("empty.txt", ""), "empty", "0", "missing or empty");
    expect_rejected(&source, "status", "2", "client exited 2");

    let truncated: Vec<&str> = text.lines().take(40).collect();
    expect_rejected(
        &work.write("trunc.txt", &format!("{}\n", truncated.join("\n"))),
        "truncated",
        "0",
        "BATTERY COMPLETE",
    );
    expect_rejected(&work.write("dup.txt", &format!("{text}{text}")), "duplicated", "0", "found 2");

    // The client-status parameter is required. Prove the requirement is real, or a later
    // convenience default would silently reinstate the assumption that nothing broke.
    assert_ne!(
        0,
        assert_battery(&source, "nostatus", None).status,
        "the oracle accepted a MISSING client status"
    );
}

#[test]
#[ignore = "needs a battery output; run `just pg yb-selftest`"]
fn every_table_assertion_rejects_its_own_mutation() {
    let source = battery_output();
    let original = read(&source).lines().count();
    let work = Scratch::new("battery-table");
    let mutated = work.join("mutated.txt");

    for (index, assertion) in assertion_table().into_iter().enumerate() {
        // grep rather than a regex dependency: the modes ARE grep's, so the mutation is deleted by
        // the same matcher the table was written against.
        let flags = if assertion.regex { "-Ev" } else { "-vF" };
        bash(
            &lane_root(),
            &format!(
                "grep {flags} -- {} '{}' > '{}' || true",
                shell_quote(&assertion.pattern),
                source.display(),
                mutated.display(),
            ),
            &[],
        );
        // A pattern that has gone stale deletes nothing, and the oracle then passes an unmutated
        // file -- which reads as "this assertion does not bite" when the control is what broke.
        assert!(
            read(&mutated).lines().count() < original,
            "the mutation for {:?} matched nothing -- this control is stale, not the oracle",
            assertion.description
        );

        // The label must NOT carry the description: the oracle echoes its label back in the
        // failure message, so passing the description as both would make the wrong-reason check
        // match the label and pass unconditionally, for every row.
        expect_rejected(&mutated, &format!("ctl-{index}"), "0", &assertion.description);
    }
}

fn shell_quote(text: &str) -> String {
    format!("'{}'", text.replace('\'', r"'\''"))
}
