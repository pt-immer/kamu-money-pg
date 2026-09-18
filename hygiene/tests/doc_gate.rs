//! Controls for the lane's rustdoc gate.
//!
//! `doc-pg` claims to fail on a broken intra-doc link. Three separate settings decide whether it
//! can: the deny that turns a rustdoc warning into an exit code, `--document-private-items`, and
//! the feature list that decides which modules the compiler hands rustdoc at all. Two earlier
//! attempts asserted those settings by reading the recipe and the Cargo configuration, and both
//! were wrong about spellings that look correct and deny nothing -- `["-D warnings"]` as one array
//! element reaches rustdoc as a single argv token, and an ambient `RUSTDOCFLAGS` replaces a
//! configured one outright.
//!
//! So this asserts the OUTCOME. A probe is planted in each region the gate must reach, `doc-pg` is
//! run once, and its report must name every one of them. No spelling of the flags satisfies that
//! without actually denying, and no region can be missing from the input set.
//!
//! It EDITS TRACKED SOURCE to do that, so it is written to leave nothing behind and to refuse
//! rather than build on wreckage: it will not start if a probe from an earlier run is still
//! present, and it fails after restoring if one survived.
//!
//! `#[ignore]` because it runs `doc-pg`, which needs a populated `PGRX_HOME`. The job running
//! `test-hygiene` has none; the `doc-gate-selftest` recipe passes `--run-ignored all` from the job
//! that does.

use std::collections::BTreeMap;
use std::path::PathBuf;

mod support;

use support::{bash, lane_root, read};

/// Every probe name carries this, so one search answers "is any of this test's damage still here".
const MARKER: &str = "kmoney_probe_";

/// The probe is inserted as a doc comment directly above the anchor, so it lands in that item's
/// documentation and inside whatever `#[cfg]` encloses it. The anchor is a WHOLE line.
struct Region {
    file: &'static str,
    anchor: &'static str,
    probe: &'static str,
}

const REGIONS: [Region; 3] = [
    Region {
        file: "kamu-money-pg/src/safe/mixed.rs",
        anchor: "/// Return the stable payload hash folded to `int4`.",
        probe: "kmoney_probe_private",
    },
    Region {
        file: "kamu-money-pg/src/safe/mixed.rs",
        anchor: "    /// Equality is currency-aware and remains a non-indexed predicate.",
        probe: "kmoney_probe_pg_test",
    },
    Region {
        file: "kamu-money-pg/src/lib.rs",
        anchor: "#[cfg(feature = \"boundary-probe\")]",
        probe: "kmoney_probe_boundary",
    },
];

/// Holds the original text of every file this test writes to, and puts it back.
///
/// One entry per FILE, not per region: two regions share `mixed.rs`, and a per-region copy would
/// save the second one after the first probe was already planted. `Drop` runs while a panicking
/// test unwinds, which is the path a `trap` in the shell version could not cover any better.
#[derive(Default)]
struct Restore {
    saved: BTreeMap<PathBuf, String>,
}

impl Restore {
    fn save(&mut self, path: PathBuf) {
        self.saved.entry(path).or_insert_with_key(|path| read(path));
    }

    fn restore(&self) {
        for (path, original) in &self.saved {
            if let Err(error) = std::fs::write(path, original) {
                eprintln!("doc-gate: FAILED to restore {}: {error}", path.display());
            }
        }
    }
}

impl Drop for Restore {
    fn drop(&mut self) {
        self.restore();
    }
}

fn plant(source: &str, anchor: &str, probe: &str) -> String {
    let indent: String = anchor.chars().take_while(|c| *c == ' ' || *c == '\t').collect();
    let mut planted = false;
    let mut lines = Vec::new();
    for line in source.lines() {
        if !planted && line == anchor {
            lines.push(format!("{indent}/// See [`{probe}`]."));
            planted = true;
        }
        lines.push(line.to_owned());
    }
    // A plant that silently did nothing would leave `doc-pg` passing for the wrong reason.
    assert!(planted, "the anchor was not matched, so its region would be probed nowhere: {anchor}");
    format!("{}\n", lines.join("\n"))
}

fn doc_pg() -> String {
    let outcome = bash(&lane_root(), "just doc-pg 2>&1", &[]);
    // Both the report and the status come from ONE run. Running `doc-pg` twice to get them
    // separately costs a second full rustdoc pass and proves nothing the first did not.
    format!("STATUS={}\n{}", outcome.status, outcome.stdout)
}

#[test]
#[ignore = "runs doc-pg, which needs a populated PGRX_HOME"]
fn every_region_the_gate_must_reach_is_reported_and_the_clean_tree_still_passes() {
    let lane = lane_root();

    // A SIGKILL, an out-of-memory kill or a cancelled CI job leaves no chance to restore, so an
    // earlier run can have left a probe in tracked source. Saving that as the "original" would
    // write it back permanently, and every later run would fail its own final control while
    // blaming the doc gate.
    for region in &REGIONS {
        assert!(
            !read(lane.join(region.file)).contains(MARKER),
            "{} still carries a probe from an interrupted run; restore it (git checkout -- {}) \
             before running this again",
            region.file,
            region.file
        );
    }

    let mut restore = Restore::default();
    for region in &REGIONS {
        let path = lane.join(region.file);
        restore.save(path.clone());
        let planted = plant(&read(&path), region.anchor, region.probe);
        std::fs::write(&path, planted).expect("the probed source is writable");
    }

    let report = doc_pg();
    restore.restore();

    assert!(!report.starts_with("STATUS=0\n"), "doc-pg exited 0 with every region probed");
    for region in &REGIONS {
        assert!(
            report.contains(&format!("unresolved link to `{}`", region.probe)),
            "doc-pg did not report {}, so that region is outside the gate",
            region.probe
        );
    }

    for region in &REGIONS {
        assert!(
            !read(lane.join(region.file)).contains(MARKER),
            "a probe survived the restore in {}; revert it before committing",
            region.file
        );
    }

    // Without this a gate that failed on EVERYTHING would satisfy every assertion above. It
    // doubles as the lane's ordinary doc build, which is why `gate-offline` composes this recipe
    // rather than `doc-pg` beside it.
    assert!(
        doc_pg().starts_with("STATUS=0\n"),
        "doc-pg fails on the unmodified tree, so the controls above prove nothing"
    );
}
