#!/usr/bin/env bash
# `kmoney` on a READ REPLICA cluster.
#
#   kamu-money-pg/yb/run-yb-readreplica.sh [yb-image] [artifact-dir] [replicas]
#
# WHY THIS EXISTS. Every piece of YugabyteDB evidence in this repository came from PRIMARY nodes:
# a single node, or a 3-node RF=3 cluster. Deployments routinely run read replicas beside those --
# a separate placement that receives data asynchronously and takes no part in the primary's Raft
# quorum -- and until this file, that entire class of node had no evidence behind it.
#
# The reason it matters has nothing to do with replication lag. **Read replica nodes are tservers,
# so they run YSQL backends, so they need the extension on their own filesystem.** `CREATE
# EXTENSION` is DDL and reaches them through the shared catalog; the shared library does not travel
# with it. A read-replica node missing `kmoney.so` does not degrade -- it fails every query
# touching a kmoney column, which is precisely the split run-yb-cluster.sh pins on the primary and
# nothing pinned here.
#
# It is also the sharpest available argument for shipping the extension IN THE NODE IMAGE
# (`just yb-node-image`): a read replica is a node someone forgets, because it is not where the
# writes go. An image cannot be forgotten.
set -euo pipefail
cd "$(dirname "$0")/../.."   # repo root

# Lock before touching the shared default run root. A distinct `KMONEY_RUN_ROOT` isolates a run;
# descendants of the release gate inherit the descriptor and re-enter.
# shellcheck source=kamu-money-pg/yb/workspace-lock.sh
source ./kamu-money-pg/yb/workspace-lock.sh
workspace_lock "$(basename "$0")" || exit 1

YB_IMAGE="${1:-$(./kamu-money-pg/yb/yb-image.sh)}"
ART="${2:-${KMONEY_RUN_ROOT:-kamu-money-pg/yb/out}}"
REPLICAS="${3:-1}"
N=3

# shellcheck source=kamu-money-pg/yb/cluster.sh
source ./kamu-money-pg/yb/cluster.sh

fail=0
ok()  { printf '  \033[32mok\033[0m    %s\n' "$1"; }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail + 1)); }

yb_cluster_up "$N" "$YB_IMAGE"
yb_read_replica_up "$REPLICAS" "$YB_IMAGE"
yb_install_extension_on_all "$ART"

echo
echo "=== 1. the extension reaches EVERY read-replica node, by hash ==="
# yb_install_extension_on_all covered the primary. The read replicas are a separate placement and
# were brought up separately, so check each group explicitly; a step
# which only walks YB_NODES silently skips them.
# The reference is what the PRIMARY is actually running, whatever put it there -- a baked image or
# a copy. Comparing a replica against the primary is the claim that matters: one library, one
# placement boundary, no divergence.
want="$(docker exec "${YB_NODES[0]}" sha256sum "$YB_LIB" | cut -d' ' -f1)"
for i in $(seq 0 $((REPLICAS - 1))); do
    name="${YB_RR_NODES[$i]}"
    # Same primitive as every other node: baked images are verified against their own manifest and
    # never written to, and under YB_REQUIRE_BAKED=1 a replica that lacks the library is a failure
    # rather than something to install onto -- a read replica is a tserver, so it is exactly as
    # much "the deployed artifact" as a primary is.
    yb_ensure_extension "$name" || { bad "$name could not be made ready"; continue; }
    got="$YB_INSTALL_SHA"
    if [ "$got" = "$want" ]; then
        ok "$name carries the same kmoney.so as the primary ($want)"
    else
        bad "$name has '$got', primary has '$want'"
    fi
done

echo
echo "=== 2. ONE CREATE EXTENSION on the primary is visible to the replica ==="
yb_sql 0 -c 'CREATE EXTENSION kmoney' >/dev/null
# Retried: table DDL right after the 3,600-object install can deterministically
# report "Restart read required" from YB's internal catalog scan.
yb_sql_retry 0 -c "CREATE TABLE rr_ledger (id int PRIMARY KEY, amount kmoney_idr)" >/dev/null
yb_sql_retry 0 -c "INSERT INTO rr_ledger VALUES (1, 'IDR 16000.000000000000000001'), \
                                          (2, 'IDR -0.000000000000000001')" >/dev/null

# Asynchronous by design, so this waits rather than assuming. A read replica that never catches up
# is a different failure from one that reports the wrong value, and the deadline separates them.
got=""
for _ in $(seq 1 60); do
    got="$(yb_rr_sql 0 -c 'SELECT count(*) FROM rr_ledger' 2>/dev/null | tr -d ' ' || true)"
    [ "${got:-0}" = "2" ] && break
    sleep 2
done
if [ "${got:-0}" = "2" ]; then
    ok "the replica sees the type, the table and both rows"
else
    bad "the replica reported '${got:-<none>}' rows after 120s"
fi

echo
echo "=== 3. values read on the replica are BYTE-IDENTICAL to the primary ==="
# The rendering is the codec, so identical text means the replica's own copy of the extension
# decoded the stored 16 bytes exactly as the primary's did. A digit lost in transit
# would show here and nowhere else.
p="$(yb_sql    0 -c "SELECT string_agg(amount::text, ' | ' ORDER BY id) FROM rr_ledger" | tr -d ' ' )"
r="$(yb_rr_sql 0 -c "SELECT string_agg(amount::text, ' | ' ORDER BY id) FROM rr_ledger" | tr -d ' ' )"
if [ -n "$p" ] && [ "$p" = "$r" ]; then
    ok "primary and replica render identically: $p"
else
    bad "primary '$p' != replica '$r'"
fi

echo
echo "=== 4. the pinned hashes agree -- the sharpest ABI signal, on replica hardware ==="
HASHES="SELECT kmoney_usd_hash('0.00'::kmoney_usd) || ' ' || kmoney_usd_hash('1.00'::kmoney_usd) \
        || ' ' || kmoney_idr_hash('1.00'::kmoney_idr) || ' ' || kmoney_usd_hash('-1.00'::kmoney_usd)"
ph="$(yb_sql 0 -c "$HASHES" | tr -d ' ')"
rh="$(yb_rr_sql 0 -c "$HASHES" | tr -d ' ')"
if [ "$ph" = "$rh" ]; then
    ok "the pinned hashes agree across the placement boundary: $ph"
else
    bad "primary hashes '$ph' != replica '$rh'"
fi

echo
echo "=== 5. NEGATIVE CONTROL: a replica without the library must FAIL LOUDLY ==="
# Without this the file is unfalsifiable. If a replica with NO kmoney.so still answered every query
# above, then those probes were measuring the primary through some other path and prove nothing
# about the replica at all.
docker exec -u 0 "${YB_RR_NODES[0]}" bash -c "rm -f $YB_LIB"
set +e
out="$(yb_rr_sql 0 -c "SELECT 'USD 1.00'::kmoney_usd::text" 2>&1)"
set -e
if printf '%s' "$out" | grep -qiE 'could not (access|open|load) file|No such file'; then
    ok "the replica refuses clearly: $(printf '%s' "$out" | head -1)"
elif printf '%s' "$out" | grep -q '^1\.00$'; then
    bad "the replica answered '1.00' with NO kmoney.so -- every probe above is suspect"
else
    bad "the replica failed, but not with a missing-library error: $(printf '%s' "$out" | head -2 | tr '\n' ' ')"
fi
# Put it back so nothing downstream inherits a deliberately broken node -- from the primary, which
# is running the same library and needs no host-side artifact to exist.
yb_restore_extension_on "${YB_RR_NODES[0]}" "${YB_NODES[0]}"

echo
if [ "$fail" -eq 0 ]; then
    echo "run-yb-readreplica: OK -- the money types behave identically on a read-replica placement,"
    echo "                    and a replica without the library fails loudly rather than diverging."
else
    echo "run-yb-readreplica: FAILED -- $fail probe(s)" >&2
    exit 1
fi
