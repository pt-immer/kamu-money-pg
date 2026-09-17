//! Negative controls for `run-suite.sh`: prove the oracle still rejects things.
//!
//! `run-suite.sh` decides whether `kmoney` behaves correctly on YugabyteDB. Nothing decides
//! whether `run-suite.sh` still decides anything. An oracle that has quietly rotted into
//! always-passing -- a normalizer that eats too much, a diff whose exit status is swallowed, a
//! completeness check that counts zero as fine -- certifies whatever the system currently does,
//! and it does so silently, which is the worst available failure mode for a money type.
//!
//! So the runner is fed a FAKE CLIENT whose output is under this file's control, and a correct
//! output must pass while each realistic corruption is rejected FOR ITS OWN REASON. It is the
//! same rule `assert_battery.rs` applies to the ABI battery's oracle, and it needs no database
//! and no Docker.

use std::path::PathBuf;

mod support;

use support::{Scratch, Shell, bash, lane_root, read};

/// The two cases cover both shapes the oracle has to police: plain values (04-sum) and error text
/// whose location prefix must be normalized away (02-text).
const CASES: [&str; 2] = ["02-text", "04-sum"];

/// A sandbox holding a copy of the real suite, so the goldens under test are the real goldens.
struct Suite {
    work: Scratch,
}

impl Suite {
    fn new(label: &str) -> Self {
        let work = Scratch::new(label);
        let source = lane_root().join("kamu-money-pg/tests/pg_regress");

        std::fs::copy(source.join("run-suite.sh"), work.join("run-suite.sh"))
            .expect("run-suite.sh is copyable");
        support::bash(work.path(), "chmod +x run-suite.sh", &[]);
        work.directory("sql");
        work.directory("expected");
        work.directory("fixtures");
        for case in CASES {
            std::fs::copy(source.join(format!("sql/{case}.sql")), work.join(format!("sql/{case}.sql")))
                .expect("the case SQL is copyable");
            std::fs::copy(
                source.join(format!("expected/{case}.out")),
                work.join(format!("expected/{case}.out")),
            )
            .expect("the golden is copyable");
        }

        // Ignores the SQL on stdin and replays a fixture, after PREPENDING a psql error-location
        // prefix to every ERROR line -- the form `psql -f` emits, which the goldens do not carry
        // because a client reading stdin omits it. That makes the run exercise the normalizer
        // rather than tiptoe around it. FAKE_STATUS lets a control make the client die.
        work.write_program(
            "fake-client",
            "#!/usr/bin/env bash\n\
             case=\"${FAKE_CASE:?}\"\n\
             sed -E \"s|^ERROR:|psql:<stdin>:${FAKE_LINE:-77}: ERROR:|\" \
             < \"$FAKE_FIXTURE_DIR/$case.fixture\"\n\
             exit \"${FAKE_STATUS:-0}\"\n",
        );

        Self { work }
    }

    fn golden(&self, case: &str) -> String {
        read(self.work.join(format!("expected/{case}.out")))
    }

    /// Put `contents` where the fake client will replay it.
    fn plant(&self, case: &str, contents: &str) {
        self.work.write(format!("fixtures/{case}.fixture"), contents);
    }

    fn expected(&self, case: &str) -> PathBuf {
        self.work.join(format!("expected/{case}.out"))
    }

    fn run(&self, case: &str, environment: &[(&str, Option<&str>)]) -> Shell {
        let fixtures = self.work.join("fixtures");
        let mut variables: Vec<(&str, Option<&str>)> = vec![
            ("FAKE_CASE", Some(case)),
            ("FAKE_FIXTURE_DIR", fixtures.to_str()),
            ("FAKE_LINE", None),
            ("FAKE_STATUS", None),
        ];
        variables.extend_from_slice(environment);
        bash(
            self.work.path(),
            &format!("./run-suite.sh --client ./fake-client --label selftest --outdir ./results {case} 2>&1"),
            &variables,
        )
    }

    fn expect_accepted(&self, case: &str, environment: &[(&str, Option<&str>)], what: &str) {
        let outcome = self.run(case, environment);
        assert_eq!(0, outcome.status, "{what} -- the runner REJECTED it: {}", outcome.output());
    }

    /// The runner must fail AND say why. A control that only checked "it failed" would be
    /// satisfied by the runner crashing on a typo, which is how a broken oracle passes its own
    /// selftest.
    fn expect_rejected(&self, case: &str, why: &str, what: &str) {
        let outcome = self.run(case, &[]);
        assert_ne!(0, outcome.status, "{what} -- the runner ACCEPTED it");
        assert!(
            outcome.output().contains(why),
            "{what} -- rejected, but for the wrong reason (wanted {why:?}): {}",
            outcome.output()
        );
    }
}

/// Replace and assert the replacement happened.
///
/// A pattern that has gone stale changes nothing, the fixture stays correct, the runner accepts it
/// -- and the control reports that the oracle failed to reject a corruption that was never
/// applied. Measured: the delete-a-refusal control below went red when the goldens dropped their
/// `CLIENT:` prefix, and only the mutation check says which of the two is broken.
fn mutate(text: &str, from: &str, to: &str) -> String {
    let mutated = text.replace(from, to);
    assert_ne!(text, mutated, "the mutation {from:?} matched nothing -- this control is stale");
    mutated
}

/// Delete every line for which `doomed` holds, asserting at least one went.
fn delete_lines(text: &str, doomed: impl Fn(&str) -> bool) -> String {
    let kept: Vec<&str> = text.lines().filter(|line| !doomed(line)).collect();
    assert!(kept.len() < text.lines().count(), "the deletion matched nothing -- this control is stale");
    format!("{}\n", kept.join("\n"))
}

/// Without this, every rejection below could be the runner rejecting everything.
#[test]
fn a_correct_output_is_accepted() {
    let suite = Suite::new("regress-positive");
    for case in CASES {
        suite.plant(case, &suite.golden(case));
        suite.expect_accepted(case, &[], case);
    }
}

/// Both halves matter. The prefix must be stripped whatever line number it carries -- AND a
/// golden with no prefix at all (which is what a stdin client produces, and what these goldens
/// are) must still match output that has one. That asymmetry is not hypothetical: the suite's
/// first run on YugabyteDB failed 9 of 11 cases on it, with byte-identical message text
/// underneath.
#[test]
fn a_psql_location_prefix_is_stripped_whatever_line_it_names() {
    let suite = Suite::new("regress-prefix");
    suite.plant("02-text", &suite.golden("02-text"));
    suite.expect_accepted("02-text", &[("FAKE_LINE", Some("4242"))], "a prefix naming line 4242");
}

/// The cursor position is a byte offset into the statement text, so merely re-indenting the .sql
/// file moves it -- which is why a trailing ` at character N` is normalized away. The narrowness
/// is the other half of the claim: the same phrase in the MIDDLE of a message must survive, or
/// the normalizer is eating message text.
///
/// The golden already CARRIES a trailing position, so the control that proves the stripping is a
/// fixture naming a different N. Appending one instead matched nothing and left the fixture equal
/// to the golden, which the runner accepted for that reason rather than for the normalizer's.
#[test]
fn the_character_position_is_stripped_only_where_it_trails() {
    let suite = Suite::new("regress-position");
    let golden = suite.golden("02-text");
    assert!(
        golden.contains(" at character 8\n"),
        "the golden no longer carries a trailing position, so this control probes nothing"
    );

    suite.plant("02-text", &mutate(&golden, " at character 8", " at character 4242"));
    suite.expect_accepted("02-text", &[], "a position naming a different offset");

    // The corruption is ONLY the position, mid-message. Adding a word as well would be rejected
    // for the word, leaving the normalizer's width untested -- measured: a normalizer widened to
    // strip the phrase anywhere survived that version of this control.
    suite.plant(
        "02-text",
        &mutate(&golden, "invalid money literal,", "invalid money literal at character 8,"),
    );
    suite.expect_rejected("02-text", "output differs", "'at character N' INSIDE a message");
}

#[test]
fn one_cent_changed_in_a_money_value_is_rejected() {
    let suite = Suite::new("regress-cent");
    suite.plant("04-sum", &mutate(&suite.golden("04-sum"), "\n10.00\n", "\n10.01\n"));
    suite.expect_rejected("04-sum", "output differs", "one cent changed");
}

#[test]
fn a_boolean_assertion_flipped_is_rejected() {
    let suite = Suite::new("regress-boolean");
    suite.plant(
        "04-sum",
        &mutate(&suite.golden("04-sum"), "empty_sum_is_null=true", "empty_sum_is_null=false"),
    );
    suite.expect_rejected("04-sum", "output differs", "a boolean assertion flipped");
}

/// The refusal MESSAGES are part of the contract: they are what an application matches on, and
/// the `#[pg_test(error = ...)]` attributes pin them character for character.
#[test]
fn a_single_letter_changed_in_a_refusal_message_is_rejected() {
    let suite = Suite::new("regress-letter");
    suite.plant(
        "02-text",
        &mutate(&suite.golden("02-text"), "invalid money literal", "invalid money literals"),
    );
    suite.expect_rejected("02-text", "output differs", "one letter changed in a refusal");
}

/// An error that stops being raised must also fail the oracle.
#[test]
fn a_refusal_that_stopped_being_raised_is_rejected() {
    let suite = Suite::new("regress-missing-error");
    let mutated = delete_lines(&suite.golden("02-text"), |line| {
        line.starts_with("ERROR:  kmoney_mixed: invalid money literal")
    });
    suite.plant("02-text", &mutated);
    suite.expect_rejected("02-text", "output differs", "a refusal that stopped being raised");
}

#[test]
fn an_incomplete_output_is_rejected_rather_than_counted_as_a_pass() {
    let suite = Suite::new("regress-complete");
    let golden = suite.golden("04-sum");

    suite.plant("04-sum", &delete_lines(&golden, |line| line == "== CASE COMPLETE: 04-sum =="));
    suite.expect_rejected("04-sum", "found 0", "a run that died before the end");

    suite.plant("04-sum", &format!("{golden}{golden}"));
    suite.expect_rejected("04-sum", "found 2", "a file holding two half-runs");

    suite.plant("04-sum", "");
    suite.expect_rejected("04-sum", "found 0", "an empty output");
}

/// Under `ON_ERROR_STOP=0` an EXPECTED SQL error does not set the exit status, so a nonzero one
/// is structural -- could not connect, backend died -- and must not be waved through just because
/// the bytes happen to match.
#[test]
fn a_perfect_output_from_a_client_that_died_is_rejected() {
    let suite = Suite::new("regress-status");
    suite.plant("04-sum", &suite.golden("04-sum"));

    let outcome = suite.run("04-sum", &[("FAKE_STATUS", Some("2"))]);
    assert_ne!(0, outcome.status, "a client that exited 2 was waved through");
    assert!(outcome.output().contains("client exited 2"), "{}", outcome.output());
}

/// Not a pass and not a skip.
#[test]
fn a_case_with_no_golden_is_rejected() {
    let suite = Suite::new("regress-no-golden");
    suite.plant("04-sum", &suite.golden("04-sum"));
    std::fs::remove_file(suite.expected("04-sum")).expect("the golden is removable");

    let outcome = suite.run("04-sum", &[]);
    assert_ne!(0, outcome.status, "a case with no golden was not rejected");
    let output = outcome.output();
    assert!(
        output.contains("no golden") || output.contains("proves nothing"),
        "rejected, but not as a missing golden: {output}"
    );
}
