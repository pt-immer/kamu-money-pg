#!/usr/bin/env bash
# Pin a benchmark container to one NUMA node, and VERIFY that the pin actually took.
#
#   source kamu-money-pg/bench/numa.sh
#   read -r -a NUMA_ARGS <<< "$(numa_docker_args)"
#   docker run -d --name "$N" ${NUMA_ARGS[@]+"${NUMA_ARGS[@]}"} ...
#   numa_verify "$N" || exit 1
#
# WHY. On a multi-socket machine a benchmark that lands anywhere competes with whatever else the
# host is doing and may allocate memory across the interconnect. Remote memory typically costs
# around twice the local latency (`numactl --hardware` prints the node distance matrix), which is
# the same order as the per-row costs these fixtures exist to resolve. Confining the measurement
# to one node -- CPUs and memory both -- removes that variance.
#
# `--cpuset-cpus` ALONE CAN DO NOTHING, AND DO IT SILENTLY. That is the part worth reading.
#
# cgroup v2 intersects a child's cpuset with its PARENT's effective set, and when the
# intersection is empty the kernel falls back to the parent's set rather than failing. systemd
# may confine the slice docker puts containers in to a subset of the machine. When those two
# facts meet, the result is:
#
#     docker inspect         CpusetCpus / CpusetMems   <- the request, faithfully stored
#     cpuset.cpus            the request               <- written into the cgroup
#     cpuset.cpus.effective  something else            <- what the kernel actually used
#     Mems_allowed_list      something else
#
# So docker reports the pin as applied, the cgroup file agrees, and the process runs somewhere
# else entirely. Without a check, a run would print "pinned to node N" in its own transcript
# while measuring a different node -- a benchmark lying about its own conditions, which is the
# failure mode this whole fixture family exists to prevent. Observed, not theorised.
#
# Inspect a host's own arrangement with:
#   numactl --hardware
#   systemctl show <slice> -p AllowedCPUs -p AllowedMemoryNodes
#   cat /sys/fs/cgroup/<slice>/cpuset.cpus.effective
#
# The mechanism that works is a cgroup parent that already OWNS the node, passed as
# `--cgroup-parent`. `node<N>.slice` is the default guess because it is a common convention; any
# host that names it differently sets BENCH_NUMA_CGROUP_PARENT, and `numa_verify` is what decides
# whether the choice worked.
#
# Pinning helps a serial process and can hurt a distributed database:
#
#   - The boundary probe -- one backend, one serial query, no storage layer -- is exactly what a
#     pin is for. Confining it removes interconnect traffic and neighbour noise.
#
#   - The YugabyteDB table fixture got WORSE. Same host, same fixture, same row count; the run
#     with the pin had a FIFTH of the ambient load and TWICE the floor instability:
#
#         unpinned   load 29    floor  70/139 ms   bracket drift  6.5%   usable
#         pinned     load  6    floor  62/183 ms   bracket drift 13.6%   REFUSED
#
#     Local memory did help the best case. It could not pay for the contention it created:
#     `yugabyted` is a master, a tserver, RocksDB compaction threads and postgres backends, and
#     confining all of them to one node makes the foreground query compete with the database's
#     own background work on a smaller pool. Across the whole machine that work has somewhere
#     else to go.
#
# So: pin a measurement that is one process doing one thing. Do not assume it helps a system
# that brings its own thread pool -- measure both and let the drift statistic decide, which is
# what it is there for.
#
# OFF BY DEFAULT. A pin is a claim about one machine's topology, and a fixture that silently
# pinned itself would produce numbers nobody can reproduce elsewhere. Unset is a no-op.
#
#   BENCH_NUMA_NODE=<n>          pin CPUs and memory to that node
#   BENCH_NUMA_CGROUP_PARENT=    the slice that owns it (default: node<n>.slice when present)

# The cgroup parent that owns this node, or empty.
_numa_parent() {
    local node="$1"
    if [ -n "${BENCH_NUMA_CGROUP_PARENT:-}" ]; then
        printf '%s' "$BENCH_NUMA_CGROUP_PARENT"
        return 0
    fi
    [ -d "/sys/fs/cgroup/node${node}.slice" ] && printf 'node%s.slice' "$node"
    return 0
}

_numa_cpus() {
    local f="/sys/devices/system/node/node${1}/cpulist"
    [ -r "$f" ] && tr -d ' \n' < "$f"
    return 0
}

# Emits the docker arguments, or nothing. Never fails the caller: an unpinnable host is a noisier
# measurement, not a broken one, and `numa_verify` is what turns a FAILED pin into a refusal.
numa_docker_args() {
    local node="${BENCH_NUMA_NODE:-}"
    [ -n "$node" ] || return 0

    local cpus parent
    cpus="$(_numa_cpus "$node")"
    if [ -z "$cpus" ]; then
        echo "numa: node ${node} has no cpulist; NOT pinning" >&2
        return 0
    fi
    parent="$(_numa_parent "$node")"
    if [ -n "$parent" ]; then
        printf -- '--cgroup-parent=%s --cpuset-cpus=%s --cpuset-mems=%s' "$parent" "$cpus" "$node"
    else
        # No owning slice found. Emit the cpuset anyway -- where the default slice is not confined
        # it is sufficient -- and let numa_verify decide whether it worked.
        echo "numa: no owning cgroup parent found for node ${node}; relying on cpuset alone," >&2
        echo "numa: which is silently ignored when the parent slice excludes that node." >&2
        printf -- '--cpuset-cpus=%s --cpuset-mems=%s' "$cpus" "$node"
    fi
}

# A CPU LIST IN CANONICAL FORM. `0-3,8` and `8,0,1,2,3` and `0,1,2,3,8` are the same set written
# three ways, and /sys, /proc and docker do not agree on which to use -- so a string comparison
# between them reports a mismatch that is not one, or misses one that is.
_numa_expand() {
    local spec="$1" part a b
    [ -n "$spec" ] || return 0
    local IFS=','
    for part in $spec; do
        case "$part" in
            '')  ;;
            *-*) a="${part%%-*}"; b="${part##*-}"; seq "$a" "$b" ;;
            *)   printf '%s\n' "$part" ;;
        esac
    done | sort -n -u | tr '\n' ',' | sed 's/,$//'
}

# DO THE MASKS AGREE? Pure -- no /proc, no /sys, no docker -- so `hygiene/tests/numa.rs` can
# drive the mismatch cases directly instead of needing a two-socket machine and a container to
# fail on.
#
#   0  both agree        1  CPU mask disagrees        2  memory mask disagrees
numa_masks_agree() {
    local want_cpus="$1" want_mems="$2" got_cpus="$3" got_mems="$4"
    [ "$(_numa_expand "$want_cpus")" = "$(_numa_expand "$got_cpus")" ] || return 1
    [ "$(_numa_expand "$want_mems")" = "$(_numa_expand "$got_mems")" ] || return 2
    return 0
}

# THE PIN IS A CLAIM UNTIL THIS RUNS. Reads the EFFECTIVE masks of the running container and
# refuses if they are not the requested node. Returns 0 when unpinned by request.
#
# Verify both CPU and memory masks. A half-applied pin is not a controlled measurement.
numa_verify() {
    local name="$1" node="${BENCH_NUMA_NODE:-}"
    [ -n "$node" ] || return 0

    local pid got_cpus got_mems want_cpus rc=0
    pid="$(docker inspect -f '{{.State.Pid}}' "$name" 2>/dev/null)" || pid=""
    if [ -z "$pid" ] || [ "$pid" = "0" ] || [ ! -r "/proc/$pid/status" ]; then
        echo "numa: cannot read the container's effective CPU mask; treat this run as UNPINNED" >&2
        return 1
    fi
    got_cpus="$(awk '/^Cpus_allowed_list:/{print $2}' "/proc/$pid/status")"
    got_mems="$(awk '/^Mems_allowed_list:/{print $2}' "/proc/$pid/status")"
    want_cpus="$(_numa_cpus "$node")"

    numa_masks_agree "$want_cpus" "$node" "$got_cpus" "$got_mems" || rc=$?
    if [ "$rc" -ne 0 ]; then
        {
            if [ "$rc" = 1 ]; then
                printf 'numa: THE PIN DID NOT TAKE. Requested the CPUs of node %s, got a different set.\n\n' "$node"
            else
                printf 'numa: THE PIN DID NOT TAKE. Requested memory node %s, got %s.\n\n' "$node" "$got_mems"
            fi
            printf '  requested Cpus               %s\n' "$want_cpus"
            printf '  container Cpus_allowed_list  %s\n' "$got_cpus"
            printf '  requested Mems               %s\n' "$node"
            printf '  container Mems_allowed_list  %s\n\n' "$got_mems"
            cat <<'EOF'
cgroup v2 intersects a child cpuset with its parent's EFFECTIVE set, and falls back to the
parent when the intersection is empty. docker reports the request as applied regardless. Where
systemd confines the default slice to a subset of the machine, `--cpuset-cpus` alone is ignored.
Check this host with:
  systemctl show <slice> -p AllowedCPUs -p AllowedMemoryNodes
  cat /sys/fs/cgroup/<slice>/cpuset.cpus.effective
then pass a slice that owns the node:
  BENCH_NUMA_CGROUP_PARENT=<slice>
Refusing rather than measuring one node and labelling it another.
EOF
        } >&2
        return 1
    fi
    echo "numa: verified -- cpus $got_cpus, memory node $got_mems" >&2
    return 0
}

# One line for the transcript. Says what was REQUESTED; `numa_verify` is what proves it.
numa_describe() {
    local node="${BENCH_NUMA_NODE:-}"
    if [ -z "$node" ]; then
        printf 'not pinned (set BENCH_NUMA_NODE=<n> to pin CPUs and memory to one node)'
        return 0
    fi
    if [ -z "$(_numa_cpus "$node")" ]; then
        printf 'requested node %s, which does not exist -- NOT pinned' "$node"
        return 0
    fi
    printf 'node %s via %s -- verified after start' "$node" "$(_numa_parent "$node")"
    [ -n "$(_numa_parent "$node")" ] || printf ' (cpuset only)'
}
