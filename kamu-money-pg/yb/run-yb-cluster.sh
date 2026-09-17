#!/usr/bin/env bash
# The kmoney extension on a three-node YugabyteDB cluster with RF=3 and moving tablets.
#
#   kamu-money-pg/yb/run-yb-cluster.sh [yb-image] [artifact-dir]
#
# This suite verifies distributed behavior:
#
#   * the .so must exist on EVERY node at the same version, and a node that lacks it must fail
#     loudly rather than diverge quietly;
#   * CREATE EXTENSION is DDL issued on ONE node that has to reach all of them -- including all
#     178 per-currency type families;
#   * a value written through node 0 is read back through node 2, having crossed the network in
#     DocDB's encoding rather than PostgreSQL's;
#   * tablets split and move between nodes while money values sit in columns.
#
# Each probe asserts a value: pinned hash results, the exact 16-byte payload, or the exact
# text form.
set -euo pipefail
cd "$(dirname "$0")/../.."   # repo root

# This script writes under ${KMONEY_RUN_ROOT:-kamu-money-pg/yb/out}. With KMONEY_RUN_ROOT unset --
# the default -- that is one tree shared with every other suite, so this is one writer among
# several that must not overlap: a release check reads the very files a hand-started run of this
# script would overwrite. Setting KMONEY_RUN_ROOT gives a run its own tree and the contention
# stops existing rather than being serialised. The lock is re-entrant, so being invoked BY
# release-check is free.
# shellcheck source=kamu-money-pg/yb/workspace-lock.sh
source "$(dirname "$0")/workspace-lock.sh"
workspace_lock "$(basename "$0")" || exit 1

YB_IMAGE="${1:-$(./kamu-money-pg/yb/yb-image.sh)}"
ART="${2:-${KMONEY_RUN_ROOT:-kamu-money-pg/yb/out}}"
N=3

# shellcheck source=kamu-money-pg/yb/cluster.sh
source ./kamu-money-pg/yb/cluster.sh

fail=0
ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }

yb_cluster_up "$N" "$YB_IMAGE"
yb_install_extension_on_all "$ART"

echo
echo "=== 1. CREATE EXTENSION on ONE node, then use the type from EVERY node ==="
# The DDL is issued exactly once, on node 0. If it does not propagate, the probes on nodes 1 and 2
# fail. `IF NOT EXISTS` is deliberately absent: this statement must be the
# one that creates it.
yb_sql 0 -c 'CREATE EXTENSION kmoney' >/dev/null
ok "CREATE EXTENSION kmoney issued on ${YB_NODES[0]}"

for i in $(seq 0 $((N - 1))); do
    got="$(yb_sql "$i" -c "SELECT 'USD 10.50'::kmoney_usd::text" | tr -d ' ')"
    if [ "$got" = "10.50" ]; then
        ok "node $i parses the tagged form and renders bare"
    else
        bad "node $i returned '$got' for 'USD 10.50'::kmoney_usd::text"
    fi
done

echo
echo "=== 2. the pinned hash values, from EVERY node ==="
# The sharpest ABI signal available, asked of each node separately. Identical values across nodes
# is not the same claim as identical values across engines: it says every node loaded the same
# library and reads the 16-byte payload at the same offsets. A single node with a stale .so shows
# up here and nowhere else.
PINNED="702888007|-1388235877|-129968833|1671845669"
for i in $(seq 0 $((N - 1))); do
    got="$(yb_sql "$i" -c "SELECT kmoney_usd_hash('0.00'::kmoney_usd) || '|' || kmoney_usd_hash('1.00'::kmoney_usd) || '|' || kmoney_idr_hash('1.00'::kmoney_idr) || '|' || kmoney_usd_hash('-1.00'::kmoney_usd)" | tr -d ' ')"
    if [ "$got" = "$PINNED" ]; then
        ok "node $i: $got"
    else
        bad "node $i hashes are $got, expected $PINNED"
    fi
done

echo
echo "=== 3. the whole case suite, from EVERY node ==="
# Not a smoke test from one node and a shrug at the rest: every ported assertion, run through
# each node in turn, against the one blessed golden set that the stock-PG15 reference is
# also checked against.
for i in $(seq 0 $((N - 1))); do
    if ./kamu-money-pg/tests/pg_regress/run-suite.sh \
            --client "$(yb_client_for "$i")" \
            --server-exec "docker exec -i ${YB_NODES[$i]} bash" \
            --label "cluster-n$i" \
            --outdir "$ART/regress-cluster-n$i" > "$ART/suite-n$i.log" 2>&1; then
        ok "node $i: suite green ($(grep -c ': ok ' "$ART/suite-n$i.log") cases)"
    else
        bad "node $i: suite FAILED"
        sed 's/^/        /' "$ART/suite-n$i.log" | tail -40
    fi
done

echo
echo "=== 4. written on one node, read back byte-identically on the others ==="
# A REPLICATED table, pre-split across tablets so the rows are genuinely distributed rather than
# all sitting on the node that wrote them.
# Retried: the internal catalog scan under CREATE ... SPLIT deterministically
# reports "Restart read required" on a freshly-installed 3,600-object catalog.
yb_sql_retry 0 -c "CREATE TABLE cross_node (id int PRIMARY KEY, amount kmoney_idr) SPLIT INTO 6 TABLETS" >/dev/null
yb_sql_retry 0 -c "INSERT INTO cross_node
             SELECT g, ('IDR ' || g || '.0' || (g % 10))::kmoney_idr FROM generate_series(1, 200) g" >/dev/null
# The whole table as ONE string: the ordered text of every row, plus a hash fold over all of them.
# Comparing a count or a sum would survive a single corrupted payload; this cannot.
FINGERPRINT_SQL="SELECT md5(string_agg(amount::text, ',' ORDER BY id)) || '/' || sum(kmoney_idr_hash(amount))::text || '/' || count(*)::text FROM cross_node"
ref="$(yb_sql_retry 0 -c "$FINGERPRINT_SQL" | tr -d ' ')"
ok "node 0 fingerprint $ref"
for i in $(seq 1 $((N - 1))); do
    got="$(yb_sql_retry "$i" -c "$FINGERPRINT_SQL" | tr -d ' ')"
    if [ "$got" = "$ref" ]; then
        ok "node $i reads back an identical fingerprint"
    else
        bad "node $i fingerprint $got != node 0 $ref"
    fi
done

# And the raw wire form, not just the text rendering: 16 bytes, the same 16 bytes, everywhere.
WIRE_SQL="SELECT encode(kmoney_idr_send(amount), 'hex') FROM cross_node WHERE id = 42"
wref="$(yb_sql_retry 0 -c "$WIRE_SQL" | tr -d ' ')"
for i in $(seq 1 $((N - 1))); do
    got="$(yb_sql_retry "$i" -c "$WIRE_SQL" | tr -d ' ')"
    if [ "$got" = "$wref" ] && [ "${#wref}" -eq 32 ]; then
        ok "node $i sends the identical 16-byte payload ($wref)"
    else
        bad "node $i payload $got != node 0 $wref (or not 16 bytes)"
    fi
done

echo
echo "=== 5. a tablet SPLIT moves the rows; the payloads must survive it ==="
# A split is the routine event that relocates rows between nodes while values sit in columns. The
# fingerprint from probe 4 is re-taken afterwards and must be identical -- so this asserts the
# money, not merely that the split completed.
MASTER="${YB_NODES[0]}:7100"
before="$(docker exec "${YB_NODES[0]}" bin/yb-admin --master_addresses "$MASTER" \
            list_tablets ysql.yugabyte cross_node 2>/dev/null | grep -c '^[0-9a-f]\{32\}' || true)"
docker exec "${YB_NODES[0]}" bin/yb-admin --master_addresses "$MASTER" \
    flush_table ysql.yugabyte cross_node 60 >/dev/null 2>&1 || true
TABLET="$(docker exec "${YB_NODES[0]}" bin/yb-admin --master_addresses "$MASTER" \
            list_tablets ysql.yugabyte cross_node 2>/dev/null | grep -oE '^[0-9a-f]{32}' | head -1 || true)"
if [ -z "$TABLET" ]; then
    bad "could not list tablets for cross_node -- the split probe proved nothing (this is a FAILURE, not a skip)"
else
    if docker exec "${YB_NODES[0]}" bin/yb-admin --master_addresses "$MASTER" \
            split_tablet "$TABLET" >/dev/null 2>&1; then
        for _ in $(seq 1 60); do
            after="$(docker exec "${YB_NODES[0]}" bin/yb-admin --master_addresses "$MASTER" \
                        list_tablets ysql.yugabyte cross_node 2>/dev/null | grep -c '^[0-9a-f]\{32\}' || true)"
            [ "${after:-0}" -gt "${before:-0}" ] && break
            sleep 2
        done
        if [ "${after:-0}" -gt "${before:-0}" ]; then
            ok "tablet $TABLET split: ${before} -> ${after} tablets"
        else
            bad "split_tablet accepted but the tablet count never rose from ${before}"
        fi
    else
        bad "yb-admin split_tablet refused -- the split probe proved nothing (this is a FAILURE, not a skip)"
    fi
    post="$(yb_sql_retry 0 -c "$FINGERPRINT_SQL" | tr -d ' ')"
    if [ "$post" = "$ref" ]; then
        ok "every payload survived the split byte-identically ($post)"
    else
        bad "fingerprint changed across the split: $post != $ref"
    fi
    for i in $(seq 1 $((N - 1))); do
        got="$(yb_sql_retry "$i" -c "$FINGERPRINT_SQL" | tr -d ' ')"
        if [ "$got" = "$ref" ]; then
            ok "node $i still agrees after the split"
        else
            bad "node $i disagrees after the split: $got"
        fi
    done
fi

echo
echo "=== 6. NEGATIVE CONTROL: a node missing the library must FAIL LOUDLY ==="
# Run last, because it breaks a node on purpose. Without this the whole file is unfalsifiable: if
# a node that has NO kmoney.so still answered every query above, then the probes were measuring
# something other than the library being present on each node.
yb_uninstall_extension_on 2
set +e
# Merged inside the container. This is the NEGATIVE control's own evidence: the branch below
# distinguishes "refused clearly" from "answered anyway", and both verdicts are read out of these
# bytes -- so they must be the bytes ysqlsh produced, in that order.
out="$(docker exec -i "${YB_NODES[2]}" bash -c \
        'exec bin/ysqlsh -h "$1" -U yugabyte -X -q -t -A -c "$2" 2>&1' \
        ysqlsh "${YB_HOSTS[2]}" "SELECT 'USD 1.00'::kmoney_usd::text")"
set -e
if printf '%s' "$out" | grep -qiE 'could not (access|open|load) file|No such file'; then
    ok "node 2 without kmoney.so refuses clearly: $(printf '%s' "$out" | head -1)"
elif printf '%s' "$out" | grep -q '^1\.00$'; then
    bad "node 2 answered '1.00' with NO kmoney.so present -- either the removal did not take, or a stale backend served it, and every probe above is suspect"
else
    bad "node 2 failed, but not with a recognisable missing-library error: $(printf '%s' "$out" | head -2 | tr '\n' ' ')"
fi
# Restore from node 0 so downstream checks do not inherit a deliberately broken node. This works
# for both baked and copied clusters without requiring a host artifact.
yb_restore_extension_on "${YB_NODES[2]}" "${YB_NODES[0]}"

echo
if [ "$fail" -eq 0 ]; then
    echo "run-yb-cluster: OK -- the money types behave identically on every node of a ${N}-node RF=3 cluster,"
    echo "                across a tablet split, and a node without the library fails loudly."
else
    echo "run-yb-cluster: FAILED -- $fail probe(s)" >&2
    exit 1
fi
