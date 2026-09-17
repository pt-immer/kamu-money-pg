//! Controls for the NUMA pin verifier in `kamu-money-pg/bench/numa.sh`.
//!
//! The comparison is a pure function precisely so these controls need neither a two-socket
//! machine nor a container that fails in the right way. Nothing here reads /sys, /proc or docker.
//!
//! NO HOST TOPOLOGY IN THIS FILE. The masks below are fixtures chosen to exercise the parser --
//! they are not this machine's, and a reader should not be able to infer one from the other.

mod support;

use support::{Shell, bash, lane_root};

/// `BENCH_NUMA_NODE` is removed rather than emptied on every call: the library reads it as
/// `${BENCH_NUMA_NODE:-}`, so an inherited value would arm the case instead of testing it.
fn numa(script: &str) -> Shell {
    bash(
        &lane_root(),
        &format!("source ./kamu-money-pg/bench/numa.sh\n{script}"),
        &[("BENCH_NUMA_NODE", None), ("BENCH_NUMA_CGROUP_PARENT", None)],
    )
}

/// /sys prints `0-3`, /proc may print `0-3` or `0,1,2,3`, and docker echoes whatever it was
/// given. A string comparison between those reports mismatches that are not mismatches -- which
/// trains whoever sees it to pass the check by loosening it.
#[test]
fn a_cpu_list_canonicalises_however_it_was_written() {
    for (spec, want) in [
        ("0-3", "0,1,2,3"),
        ("0,1,2,3", "0,1,2,3"),
        ("3,1,0,2", "0,1,2,3"),
        ("0-1,4-5", "0,1,4,5"),
        ("7", "7"),
        ("", ""),
    ] {
        let outcome = numa(&format!("_numa_expand '{spec}'"));
        assert_eq!(0, outcome.status, "_numa_expand {spec:?} failed: {}", outcome.stderr);
        assert_eq!(want, outcome.stdout.trim_end_matches('\n'), "{spec:?} canonicalised wrongly");
    }
}

/// Both masks are compared, and each mismatch is distinguishable: 1 is the CPU set, 2 the memory
/// node. A verifier that returned one status for both would print a message naming the wrong one.
#[test]
fn each_mask_is_compared_and_its_mismatch_is_distinguishable() {
    for (want_status, arguments, what) in [
        (0, "'0-3' '1' '0,1,2,3' '1'", "identical sets written two ways agree"),
        (1, "'0-3' '1' '8-11' '1'", "CPUs on the wrong node are refused, memory node right"),
        (2, "'0-3' '1' '0-3' '0'", "memory on the wrong node is refused, CPU set right"),
        (1, "'0-3' '1' '0-1' '1'", "a subset of the node's CPUs is not close enough"),
    ] {
        let outcome = numa(&format!("numa_masks_agree {arguments}"));
        assert_eq!(want_status, outcome.status, "{what}: got {}", outcome.status);
    }
}

/// Reported as a mismatch of some kind. Which of the two it names is not the claim here -- the
/// claim is that a container pinned to neither the requested CPUs nor its memory is refused.
#[test]
fn both_masks_wrong_is_refused() {
    assert_ne!(0, numa("numa_masks_agree '0-3' '1' '8-11' '0'").status);
}

/// A fixture that silently pinned itself would produce numbers nobody can reproduce elsewhere, so
/// unset must mean unset -- including in the line the transcript prints.
#[test]
fn with_no_node_requested_the_verifier_is_a_no_op_rather_than_a_refusal() {
    let outcome = numa("numa_verify 'no-such-container'");
    assert_eq!(0, outcome.status, "an unpinned run was refused by the pin verifier: {}", outcome.stderr);

    let described = numa("numa_describe");
    assert_eq!(0, described.status, "numa_describe failed: {}", described.stderr);
    assert!(
        described.stdout.contains("not pinned"),
        "numa_describe claimed a pin with no node requested: {}",
        described.stdout
    );
}
