#!/usr/bin/env bash
# Restart and node failure, with `kmoney` data resident.
#
#   kamu-money-pg/yb/run-yb-resilience.sh [yb-image] [artifact-dir]
#
# Probe routine node restart, failure, and rejoin while `kmoney` data remains resident.
#
# A rolling version upgrade is out of scope because it requires a second YugabyteDB image digest
# and a second artifact built against that image's headers. See `yb/RUNBOOK.md`.
#
# THE ASSERTION IS ALWAYS A VALUE. Every probe re-takes the same fingerprint: the ordered text of
# every row, folded with the pinned hash, plus the row count. "The query succeeded after the
# restart" is not the claim; "every 16-byte payload is the one that went in" is.
set -euo pipefail
cd "$(dirname "$0")/../.."   # repo root

# Lock before touching the shared default run root. A distinct `KMONEY_RUN_ROOT` isolates a run;
# descendants of the release gate inherit the descriptor and re-enter.
# shellcheck source=kamu-money-pg/yb/workspace-lock.sh
source ./kamu-money-pg/yb/workspace-lock.sh
workspace_lock "$(basename "$0")" || exit 1

YB_IMAGE="${1:-$(./kamu-money-pg/yb/yb-image.sh)}"
ART="${2:-${KMONEY_RUN_ROOT:-kamu-money-pg/yb/out}}"
N=3

# shellcheck source=kamu-money-pg/yb/cluster.sh
source ./kamu-money-pg/yb/cluster.sh

fail=0
ok()  { printf '  \033[32mok\033[0m    %s\n' "$1"; }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }

yb_cluster_up "$N" "$YB_IMAGE"
yb_install_extension_on_all "$ART"
yb_sql 0 -c 'CREATE EXTENSION kmoney' >/dev/null

FINGERPRINT="SELECT md5(string_agg(amount::text, ',' ORDER BY id)) || '/' || sum(kmoney_idr_hash(amount))::text || '/' || count(*)::text FROM resilient"
HASHES="SELECT kmoney_usd_hash('0.00'::kmoney_usd) || '|' || kmoney_usd_hash('1.00'::kmoney_usd) || '|' || kmoney_idr_hash('1.00'::kmoney_idr) || '|' || kmoney_usd_hash('-1.00'::kmoney_usd)"
PINNED="702888007|-1388235877|-129968833|1671845669"

echo
echo "=== setup: 500 kmoney_idr rows, RF=3, pre-split across 6 tablets ==="
# Retried: the internal catalog scan under CREATE ... SPLIT deterministically
# reports "Restart read required" on a freshly-installed 3,600-object catalog.
yb_sql_retry 0 -c "CREATE TABLE resilient (id int PRIMARY KEY, amount kmoney_idr) SPLIT INTO 6 TABLETS" >/dev/null
yb_sql_retry 0 -c "INSERT INTO resilient
             SELECT g, ('IDR ' || g || '.' || lpad((g % 100)::text, 2, '0') || '000000000000001')::kmoney_idr
               FROM generate_series(1, 500) g" >/dev/null
REF="$(yb_sql_retry 0 -c "$FINGERPRINT" | tr -d ' ')"
ok "fingerprint $REF"

# Wait until a node answers again, or give up loudly. A resilience probe that silently proceeds
# against a half-started node measures nothing.
wait_node() {
    local i="$1"
    for _ in $(seq 1 120); do
        yb_sql "$i" -c 'SELECT 1' >/dev/null 2>&1 && return 0
        sleep 2
    done
    return 1
}

echo
echo "=== 1. a node RESTARTS; values and the pinned hashes are intact ==="
# `docker restart` stops and starts the whole yugabyted process tree -- the postmaster included --
# so every backend is new and the library is loaded again from disk.
docker restart "${YB_NODES[1]}" >/dev/null
if wait_node 1; then
    ok "${YB_NODES[1]} came back"
else
    bad "${YB_NODES[1]} never came back after a restart"
fi
got="$(yb_sql 1 -c "$FINGERPRINT" | tr -d ' ')"
if [ "$got" = "$REF" ]; then
    ok "the restarted node reads every payload back identically"
else
    bad "restarted node fingerprint $got != $REF"
fi
got="$(yb_sql 1 -c "$HASHES" | tr -d ' ')"
if [ "$got" = "$PINNED" ]; then
    ok "the restarted node still produces the pinned hashes"
else
    bad "restarted node hashes $got != $PINNED"
fi

echo
echo "=== 2. a node DIES; reads and writes continue on the survivors (RF=3) ==="
# This is the property RF=3 is bought for, and the one a single-node harness structurally cannot
# observe. Writes must keep committing while a third of the cluster is gone.
docker stop "${YB_NODES[2]}" >/dev/null
ok "${YB_NODES[2]} stopped"

if got="$(yb_sql 0 -c "$FINGERPRINT" 2>/dev/null | tr -d ' ')" && [ "$got" = "$REF" ]; then
    ok "a surviving node still reads every payload identically"
else
    bad "with one node down the fingerprint is '$got', expected $REF"
fi

if yb_sql 0 -c "INSERT INTO resilient VALUES (1001, 'IDR 777.77')" >/dev/null 2>&1; then
    ok "a write COMMITTED while a node was down"
else
    bad "no write could commit with one node down -- RF=3 should tolerate this"
fi
got="$(yb_sql 0 -c "SELECT amount::text FROM resilient WHERE id = 1001" | tr -d ' ')"
if [ "$got" = "777.77" ]; then
    ok "the value written during the outage reads back as 777.77"
else
    bad "the value written during the outage reads back as '$got'"
fi

echo
echo "=== 3. the node REJOINS and catches up; it must agree, not merely answer ==="
docker start "${YB_NODES[2]}" >/dev/null
if wait_node 2; then
    ok "${YB_NODES[2]} rejoined"
else
    bad "${YB_NODES[2]} never rejoined"
fi

# The row written while this node was DOWN is the one that matters: it must be here now, and be
# byte-identical. Replication is given a bounded window to catch up -- and running out of window is
# a failure, never a shrug.
REF_AFTER="$(yb_sql 0 -c "$FINGERPRINT" | tr -d ' ')"
caught=0
for _ in $(seq 1 60); do
    got="$(yb_sql 2 -c "$FINGERPRINT" 2>/dev/null | tr -d ' ')" || true
    [ "$got" = "$REF_AFTER" ] && { caught=1; break; }
    sleep 2
done
if [ "$caught" -eq 1 ]; then
    ok "the rejoined node agrees with the cluster: $REF_AFTER"
else
    bad "the rejoined node reports '$got', the cluster reports '$REF_AFTER'"
fi
got="$(yb_sql 2 -c "SELECT amount::text FROM resilient WHERE id = 1001" | tr -d ' ')"
if [ "$got" = "777.77" ]; then
    ok "it has the row written while it was down, byte-identically"
else
    bad "the rejoined node reports '$got' for the row written during its outage"
fi
got="$(yb_sql 2 -c "$HASHES" | tr -d ' ')"
if [ "$got" = "$PINNED" ]; then
    ok "and still produces the pinned hashes"
else
    bad "rejoined node hashes $got != $PINNED"
fi

echo
echo "=== 4. the full case suite, on the cluster that has been through all of that ==="
# A cluster that survived a restart and a failure is not the same thing as a cluster on which the
# extension is still wholly correct. Cheap to check, and it is the whole contract rather than a
# fingerprint.
if ./kamu-money-pg/tests/pg_regress/run-suite.sh \
        --client "$(yb_client_for 2)" \
        --server-exec "docker exec -i ${YB_NODES[2]} bash" \
        --label resilience \
        --outdir "$ART"/regress-resilience > "$ART"/suite-resilience.log 2>&1; then
    ok "suite green on the recovered node"
else
    bad "suite FAILED on the recovered node"
    tail -40 "$ART"/suite-resilience.log | sed 's/^/        /'
fi

echo
echo "NOT COVERED, deliberately: a rolling VERSION upgrade. It needs a second image digest and a"
echo "second from-source artifact build against that image's headers. See yb/RUNBOOK.md."
echo
if [ "$fail" -eq 0 ]; then
    echo "run-yb-resilience: OK -- money data survives a node restart, a node failure with writes"
    echo "                   continuing, and a rejoin, byte-identically each time."
else
    echo "run-yb-resilience: FAILED -- $fail probe(s)" >&2
    exit 1
fi
