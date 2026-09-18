#!/usr/bin/env bash
# Bring up a multi-node YugabyteDB cluster on a private docker network, install `kmoney` on every
# node, and give the caller the addresses. Sourced, not executed.
#
#   source kamu-money-pg/yb/cluster.sh
#   yb_cluster_up 3 "$YB_REF"     # nodes, image identity  -> sets YB_NODES / YB_HOSTS / YB_NET
#   yb_install_extension_on_all   # docker cp the artifact into every node
#   yb_sql <index> "SELECT 1"     # run SQL on node <index> (0-based)
#   # teardown is automatic: yb_cluster_up installs the trap
#
# The cluster proves node-wide extension installation, distributed DDL, and
# values moving during tablet splits. Every container and network carries this
# run's label; cleanup uses only that label and traps INT/TERM/HUP/EXIT.
set -euo pipefail

# Installation and artifact-hash verification are shared with single-node
# harnesses through install.sh.
# shellcheck source=kamu-money-pg/yb/install.sh
source "$(dirname "${BASH_SOURCE[0]}")/install.sh"

YB_NODES=()      # container names, node 0 first
YB_HOSTS=()      # the address each node's YSQL is listening on
YB_NET=""
YB_RUN_ID=""
YB_IMAGE_REF=""

# Node resource caps, defined once for every harness that starts one. See node-limits.sh.
# shellcheck source=kamu-money-pg/yb/node-limits.sh
source "$(dirname "${BASH_SOURCE[0]}")/node-limits.sh"

# Shared retry classifier for every cluster script. YugabyteDB SERIALIZABLE
# transactions can report deadlock instead of serialization failure; both mean
# abort and retry. `ysqlsh` exposes message text here, so this harness cannot use
# the less fragile SQLSTATE classification expected in an application.
# shellcheck disable=SC2034 # read by the scripts that source this file, not by this file
YB_RETRYABLE='could not serialize|conflict|restart read|Try again|deadlock|expired or aborted|Restart'

yb_cleanup() {
    # Scoped to THIS run's label. Never a name prefix, never an ancestor image, never a prune.
    local ids
    ids=$(docker ps -aq --filter "label=kamu-money-pg.cluster=${YB_RUN_ID}" 2>/dev/null || true)
    if [ -n "$ids" ]; then
        # shellcheck disable=SC2086 # word splitting is the point; ids is a list
        docker rm -f $ids >/dev/null 2>&1 || true
    fi
    [ -n "$YB_NET" ] && docker network rm "$YB_NET" >/dev/null 2>&1
    [ -n "$YB_RUN_ID" ] && rm -f "${KMONEY_RUN_ROOT:-kamu-money-pg/yb/out}/client-${YB_RUN_ID}-n"*.sh 2>/dev/null
    return 0
}

# Run SQL on a node by index. Every caller goes through this so no invocation forgets -X (which
# would let a stray ~/.psqlrc change the output) or the host discovery below.
yb_sql() {
    local i="$1"; shift
    docker exec -i "${YB_NODES[$i]}" bin/ysqlsh -h "${YB_HOSTS[$i]}" -U yugabyte -X -q -t -A "$@"
}

# `yb_sql` under the shared retry classifier, for statements that can hit a
# TRANSIENT YugabyteDB abort. Needed deterministically since the extension grew
# to ~3,600 catalog objects: the internal catalog scan under
# `CREATE TABLE ... SPLIT` reliably reports "Restart read required" on a
# freshly-installed cluster, and YB's transparent read-restart retries do not
# cover it. Only output matching YB_RETRYABLE is retried; any other failure
# returns immediately with its output. This retries the INFRASTRUCTURE, never
# the value -- a wrong fingerprint is not retryable by construction, because
# the classifier matches abort phrasing and not content.
yb_sql_retry() {
    local attempt out rc
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        set +e
        out="$(yb_sql "$@" 2>&1)"; rc=$?
        set -e
        if [ "$rc" -eq 0 ]; then
            printf '%s\n' "$out"
            return 0
        fi
        if ! printf '%s' "$out" | grep -qiE "$YB_RETRYABLE"; then
            printf '%s\n' "$out" >&2
            return "$rc"
        fi
        sleep "$attempt"
    done
    printf '%s\n' "$out" >&2
    echo "yb_sql_retry: still retryable after 10 attempts -- treating as real" >&2
    return 1
}

# A client wrapper for node <index>, for run-suite.sh's --client. Echoes the wrapper's PATH.
#
# A generated wrapper merges ysqlsh streams inside the container and survives run-suite.sh
# appending client flags.
yb_client_for() {
    local i="$1"
    local w="${KMONEY_RUN_ROOT:-kamu-money-pg/yb/out}/client-${YB_RUN_ID}-n$i.sh"
    mkdir -p "$(dirname "$w")"
    cat > "$w" <<EOF
#!/usr/bin/env bash
exec docker exec -i ${YB_NODES[$i]} bash -c 'exec bin/ysqlsh -h ${YB_HOSTS[$i]} -U yugabyte "\$@" 2>&1' ysqlsh "\$@"
EOF
    chmod +x "$w"
    echo "$w"
}

yb_wait_ready() {
    local name="$1" host=""
    for _ in $(seq 1 150); do
        # yugabyted binds YSQL to the node's advertised address, not loopback -- discover it
        # rather than assuming, exactly as run-yb.sh does.
        host="$(docker exec "$name" hostname -i 2>/dev/null | awk '{print $1}')" || true
        if [ -n "${host:-}" ] && docker exec "$name" bin/ysqlsh -h "$host" -U yugabyte -X -q \
             -c 'SELECT 1' >/dev/null 2>&1; then
            echo "$host"
            return 0
        fi
        sleep 2
    done
    return 1
}

yb_cluster_up() {
    local n="${1:-3}"
    YB_IMAGE_REF="${2:?yb_cluster_up: the resolved image identity is required, never a tag}"

    YB_RUN_ID="kmoney-cl-$$-$(od -An -N4 -tx4 /dev/urandom | tr -d ' \n')"
    YB_NET="$YB_RUN_ID-net"
    trap yb_cleanup EXIT INT TERM HUP

    echo "cluster: $n node(s), image $YB_IMAGE_REF, run $YB_RUN_ID"
    docker network create "$YB_NET" >/dev/null

    local i name
    for i in $(seq 0 $((n - 1))); do
        name="$YB_RUN_ID-n$i"
        if [ "$i" -eq 0 ]; then
            # RF=3 is what makes the failover and tablet-movement probes mean anything: with RF=1
            # a node loss is data loss and there is nothing to observe about availability.
            docker run -d --name "$name" --network "$YB_NET" \
                --memory "$YB_NODE_MEM" --memory-swap "$YB_NODE_MEM" \
                --label "kamu-money-pg.cluster=${YB_RUN_ID}" \
                --label "kamu-money-pg.revision=$(git rev-parse --short HEAD 2>/dev/null || echo nogit)" \
                "$YB_IMAGE_REF" bin/yugabyted start --background=false \
                    --advertise_address="$name" --cloud_location=cloud1.region1.zone"$i" \
                    --tserver_flags="memory_limit_hard_bytes=$YB_TSERVER_MEM_BYTES" \
                    --master_flags="memory_limit_hard_bytes=$YB_MASTER_MEM_BYTES" \
                    --fault_tolerance=zone >/dev/null
        else
            docker run -d --name "$name" --network "$YB_NET" \
                --memory "$YB_NODE_MEM" --memory-swap "$YB_NODE_MEM" \
                --label "kamu-money-pg.cluster=${YB_RUN_ID}" \
                --label "kamu-money-pg.revision=$(git rev-parse --short HEAD 2>/dev/null || echo nogit)" \
                "$YB_IMAGE_REF" bin/yugabyted start --background=false \
                    --advertise_address="$name" --join="$YB_RUN_ID-n0" \
                    --tserver_flags="memory_limit_hard_bytes=$YB_TSERVER_MEM_BYTES" \
                    --master_flags="memory_limit_hard_bytes=$YB_MASTER_MEM_BYTES" \
                    --cloud_location=cloud1.region1.zone"$i" --fault_tolerance=zone >/dev/null
        fi
        YB_NODES+=("$name")
        echo "cluster: started $name"
        # Node 0 must be serving before the others try to join it.
        if [ "$i" -eq 0 ]; then
            local h
            h="$(yb_wait_ready "$name")" || { echo "cluster: node 0 never became ready" >&2; return 1; }
            YB_HOSTS+=("$h")
            echo "cluster: $name ready at $h"
        fi
    done

    for i in $(seq 1 $((n - 1))); do
        local h
        h="$(yb_wait_ready "${YB_NODES[$i]}")" \
            || { echo "cluster: ${YB_NODES[$i]} never became ready" >&2; return 1; }
        YB_HOSTS+=("$h")
        echo "cluster: ${YB_NODES[$i]} ready at $h"
    done

    # MEMBERSHIP IS ASSERTED, NOT ASSUMED. Every node answering SELECT 1 is consistent with n
    # separate single-node clusters that never joined -- which would make every cross-node claim
    # below vacuously true. yb_servers() is the cluster's own view of itself.
    local seen deadline=0
    while [ "$deadline" -lt 60 ]; do
        seen="$(yb_sql 0 -c 'SELECT count(*) FROM yb_servers()' 2>/dev/null | tr -d ' ' || true)"
        [ "${seen:-0}" = "$n" ] && break
        sleep 2
        deadline=$((deadline + 1))
    done
    [ "${seen:-0}" = "$n" ] || {
        echo "cluster: yb_servers() reports ${seen:-0} node(s), expected $n -- they did not form one cluster" >&2
        return 1
    }
    echo "cluster: yb_servers() confirms $n node(s) in ONE cluster"
}

# Ensure every node carries the extension, and PROVE it -- by hash, PER NODE. `CREATE EXTENSION`
# is run separately, once, by the caller: the point of the cluster probes is that ONE DDL
# statement has to reach all of them while the shared library does not travel with it.
#
# The baked-versus-copied decision, the manifest lookup and the hash comparison all live in
# `yb_ensure_extension` (install.sh), because the single-node harnesses need exactly the same
# rules and a second copy of them would drift. This function is the LOOP and the reporting.
#
# PER NODE, not once: "the DDL propagates, the shared library does not" is the failure this whole
# file exists to surface, and a copy loop that reports success because `docker cp` exited 0 is not
# evidence that the bytes arrived intact on node 3 of 5.
yb_install_extension_on_all() {
    local art="${1:-${KMONEY_RUN_ROOT:-kamu-money-pg/yb/out}}"
    local name first_mode="" first_sha=""

    for name in "${YB_NODES[@]}"; do
        yb_ensure_extension "$name" "$art" || return 1
        if [ -z "$first_mode" ]; then
            first_mode="$YB_INSTALL_MODE"
            first_sha="$YB_INSTALL_SHA"
            [ "$first_mode" = "baked" ] && \
                echo "cluster: the image already carries kmoney -- verifying per node, not installing"
        elif [ "$YB_INSTALL_SHA" != "$first_sha" ]; then
            # Every node passed its OWN check and they still disagree, which means two nodes are
            # running different libraries -- each self-consistent, and the cluster incoherent.
            echo "cluster: $name carries a DIFFERENT kmoney.so from ${YB_NODES[0]}" >&2
            echo "cluster:   ${YB_NODES[0]}: $first_sha" >&2
            echo "cluster:   $name: $YB_INSTALL_SHA" >&2
            return 1
        fi
    done
    echo "cluster: kmoney verified by hash on all ${#YB_NODES[@]} node(s) ($first_mode)"
}

# --- read replicas ------------------------------------------------------------------------------
# A read replica cluster is a SEPARATE placement that receives data asynchronously and takes no
# part in the primary's Raft quorum. It matters here for one reason that has nothing to do with
# replication: **its nodes are tservers, so they run YSQL backends, so they need the extension**.
# The catalog reaches them automatically -- `CREATE EXTENSION` is DDL -- but the shared library
# does not, and a read-replica node without it fails every query touching a kmoney column.
#
# That is the same split `yb_uninstall_extension_on` exists to prove on the primary, and until now
# nothing exercised it on a replica. Deployments that run read replicas therefore had a whole class
# of node with no evidence behind it.
#
# Sets YB_RR_NODES / YB_RR_HOSTS. The containers carry this run's label like every other, so
# yb_cleanup reaps them without knowing they exist.
YB_RR_NODES=()
YB_RR_HOSTS=()

yb_read_replica_up() {
    local n="${1:-1}"
    local image="${2:?yb_read_replica_up: the resolved image identity is required}"
    local zone="rr1"

    # OUTPUT IS CAPTURED AND REPORTED, never discarded. `yugabyted` writes its failures to STDOUT,
    # so an earlier `>/dev/null` here produced a run that died with `set -e` and printed nothing at
    # all -- the single least debuggable failure mode a harness can have.
    # Merged INSIDE the container, like every other captured `docker exec` here: the host cannot
    # order two separately multiplexed channels, and this output is read to diagnose a failure --
    # a diagnosis assembled from lines in the wrong order is worse than none.
    local out
    if ! out="$(docker exec "${YB_NODES[0]}" bash -c \
                    'exec bin/yugabyted configure data_placement --fault_tolerance=zone 2>&1')"; then
        echo "cluster: configure data_placement failed:" >&2
        printf '%s\n' "$out" | sed 's/^/cluster:   /' >&2
        return 1
    fi

    # Start replica nodes before configuration: `configure_read_replica new` discovers their
    # tservers to assign the placement UUID and fails when that set is empty.
    local i name h
    for i in $(seq 0 $((n - 1))); do
        name="$YB_RUN_ID-rr$i"
        docker run -d --name "$name" --network "$YB_NET" \
            --memory "$YB_NODE_MEM" --memory-swap "$YB_NODE_MEM" \
            --label "kamu-money-pg.cluster=${YB_RUN_ID}" \
            --label "kamu-money-pg.revision=$(git rev-parse --short HEAD 2>/dev/null || echo nogit)" \
            "$image" bin/yugabyted start --background=false \
                --advertise_address="$name" --join="$YB_RUN_ID-n0" --read_replica \
                --tserver_flags="memory_limit_hard_bytes=$YB_TSERVER_MEM_BYTES" \
                --cloud_location="cloud1.region1.${zone}" >/dev/null
        YB_RR_NODES+=("$name")
        echo "cluster: started read replica $name"
    done

    for i in $(seq 0 $((n - 1))); do
        h="$(yb_wait_ready "${YB_RR_NODES[$i]}")" \
            || { echo "cluster: ${YB_RR_NODES[$i]} never became ready" >&2; return 1; }
        YB_RR_HOSTS+=("$h")
        echo "cluster: ${YB_RR_NODES[$i]} ready at $h"
    done

    # NOW the replicas exist, so there is something for this to discover and place.
    # Arguments passed positionally into the container shell rather than interpolated into its
    # script, so `$n` and `$zone` stay host-side values and never become shell syntax in there.
    if ! out="$(docker exec "${YB_NODES[0]}" bash -c \
                    'exec bin/yugabyted configure_read_replica new --rf="$1" \
                        --data_placement_constraint="$2" 2>&1' \
                    yugabyted "$n" "cloud1.region1.${zone}:1")"; then
        echo "cluster: configure_read_replica new failed:" >&2
        printf '%s\n' "$out" | sed 's/^/cluster:   /' >&2
        return 1
    fi
    printf '%s\n' "$out" | sed 's/^/cluster:   /'

    # MEMBERSHIP ASSERTED, NOT ASSUMED -- the same rule the primary follows. A read replica that
    # silently failed to join would answer every query below from a cluster of its own, making
    # every claim about replication vacuously true.
    local seen deadline=0 want=$(( ${#YB_NODES[@]} + n ))
    while [ "$deadline" -lt 60 ]; do
        seen="$(yb_sql 0 -c 'SELECT count(*) FROM yb_servers()' 2>/dev/null | tr -d ' ' || true)"
        [ "${seen:-0}" = "$want" ] && break
        sleep 2
        deadline=$((deadline + 1))
    done
    [ "${seen:-0}" = "$want" ] || {
        echo "cluster: yb_servers() reports ${seen:-0}, expected $want -- the read replica did not join" >&2
        return 1
    }
    echo "cluster: yb_servers() confirms $want node(s): ${#YB_NODES[@]} primary + $n read replica"
}

# Run SQL on a READ REPLICA by index, with follower reads enabled -- a read replica serves stale
# reads and refuses to pretend otherwise, so the session has to say it accepts that.
yb_rr_sql() {
    local i="$1"; shift
    docker exec -i "${YB_RR_NODES[$i]}" bin/ysqlsh -h "${YB_RR_HOSTS[$i]}" -U yugabyte -X -q -t -A \
        -c 'SET session characteristics as transaction read only' \
        -c 'SET yb_read_from_followers = true' "$@"
}

# Copy the extension files OFF one node -- used by the negative control, which needs a node that
# genuinely lacks the library rather than one we merely did not copy to.
yb_uninstall_extension_on() {
    local i="$1"
    docker exec -u 0 "${YB_NODES[$i]}" bash -c \
        'rm -f /home/yugabyte/postgres/lib/kmoney.so' \
        || return 1
    echo "cluster: removed kmoney.so from ${YB_NODES[$i]}"
}
