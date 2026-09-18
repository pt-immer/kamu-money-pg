#!/usr/bin/env bash
# Concurrency, distributed transactions, and the invariant this type exists for.
#
#   kamu-money-pg/yb/run-yb-concurrent.sh [yb-image] [artifact-dir] [workers] [transfers-each]
#
# YugabyteDB's DocDB transaction layer owns snapshot semantics, conflict detection, and retry
# behavior, so in-backend PostgreSQL tests cannot establish this contract.
#
# N workers transfer money between accounts. The exact final sum must equal the seed; a torn
# payload, lost update, or half-applied transaction changes that total.
#
# A positive control forces a serialization failure so a conflict-free run cannot leave retry
# handling untested.
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
WORKERS="${3:-8}"
EACH="${4:-25}"
ACCOUNTS=10
SEED_EACH="IDR 1000.00"
N=3

# shellcheck source=kamu-money-pg/yb/cluster.sh
source ./kamu-money-pg/yb/cluster.sh

fail=0
ok()  { printf '  \033[32mok\033[0m    %s\n' "$1"; }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }

# The retry classifier now lives in cluster.sh as `YB_RETRYABLE`, shared with run-yb-soak.sh --
# which had its own drifted copy. See the reasoning there; this alias keeps the local reads short.
RETRYABLE="$YB_RETRYABLE"

yb_cluster_up "$N" "$YB_IMAGE"
yb_install_extension_on_all "$ART"
yb_sql 0 -c 'CREATE EXTENSION kmoney' >/dev/null

WORKDIR="$ART/concurrent"
mkdir -p "$WORKDIR"

echo
echo "=== setup: $ACCOUNTS accounts, seeded $SEED_EACH each ==="
# The column is TYPE-pinned. A wallet's amount column is pinned to one currency in real schemas,
# and pinning it here means a cross-currency write would be refused by the column rather than
# quietly accepted and only noticed by the conservation check at the end.
yb_sql 0 -c "CREATE TABLE account (id int PRIMARY KEY, balance kmoney_idr) SPLIT INTO 6 TABLETS" >/dev/null
yb_sql 0 -c "INSERT INTO account SELECT g, '$SEED_EACH'::kmoney_idr FROM generate_series(1, $ACCOUNTS) g" >/dev/null
# A ledger of every leg, so conservation can be checked a second, independent way: the debits and
# credits must cancel to exactly zero regardless of what the balances say.
yb_sql 0 -c "CREATE TABLE ledger (seq bigserial PRIMARY KEY, account_id int NOT NULL, delta kmoney_idr NOT NULL)" >/dev/null

# The ROW AGGREGATE -- the path an application actually writes to total a
# ledger column, so it is the path that should be under concurrent load here.
# The ledger-leg check further down runs the same aggregate over a DIFFERENT
# table and access path, so conservation is still cross-checked rather than one
# query agreeing with itself. (0.2.0 has no variadic sum form to diversify with.)
TOTAL_SQL="SELECT sum(balance)::text FROM account"
opening="$(yb_sql 0 -c "$TOTAL_SQL" | tr -d ' ' | sed 's/IDR/IDR /')"
ok "opening total $opening"

echo
echo "=== 1. $WORKERS concurrent workers x $EACH balanced transfers each ==="
# Each transfer is ONE distributed transaction touching two rows on (probably) different tablets,
# and therefore different nodes. Workers are spread across all three nodes so the traffic is not
# all funnelled through one coordinator.
#
# The retry loop is here rather than in SQL because that is where it lives in a real application:
# YugabyteDB can refuse a transaction with a retryable error, and the caller's contract is to try
# again. Counting the retries makes them evidence instead of a rumour.
worker() {
    # TWO `local`s, and this is not a style choice. Bash expands every word on a command line
    # BEFORE running it, so in `local w="$1" node=$((w % N))` the arithmetic is evaluated while
    # `w` is still unset -- `node` was 0 for EVERY worker, and this harness spent its life
    # reporting "on $N nodes" while talking to node 0 alone. ShellCheck SC2318 names it.
    local w="$1"
    local node=$((w % N))
    local i from to frac amt neg out retries=0 committed=0
    for i in $(seq 1 "$EACH"); do
        from=$(( (w * 7 + i * 3) % ACCOUNTS + 1 ))
        to=$(( (w * 5 + i * 11) % ACCOUNTS + 1 ))
        [ "$from" = "$to" ] && to=$(( to % ACCOUNTS + 1 ))
        # Deterministic amounts, but with fractional digits below any currency's minor unit, so a
        # rounding bug anywhere in the path shows up as a conservation failure.
        #
        # The negative literal is built as `IDR -0.x`, NOT `-IDR 0.x`. The sign belongs to the
        # amount, not to the money: the input function refuses the latter, and correctly --
        # a leading `-` before the ISO code is not a money literal in any dialect. Caught by this
        # harness's first real run, which is the right place for a harness bug to surface.
        frac="$(printf '%02d' $(( (i * 13 + w) % 97 + 1 )))000000000000001"
        amt="IDR 0.$frac"
        neg="IDR -0.$frac"
        local attempt
        for attempt in 1 2 3 4 5 6 7 8 9 10; do
            set +e
            # Merged inside the container: `out` decides retry-vs-fail below, so a line spliced
            # across the two multiplexed channels could turn a real refusal into an unrecognised
            # one -- reported as a failure of the money, not of the harness.
            out=$(docker exec -i "${YB_NODES[$node]}" bash -c \
                    'exec bin/ysqlsh -h "$1" -U yugabyte -X -q -t -A -v ON_ERROR_STOP=1 2>&1' \
                    ysqlsh "${YB_HOSTS[$node]}" <<SQL
BEGIN;
UPDATE account SET balance = balance - '$amt'::kmoney_idr WHERE id = $from;
UPDATE account SET balance = balance + '$amt'::kmoney_idr WHERE id = $to;
INSERT INTO ledger (account_id, delta) VALUES ($from, '$neg'), ($to, '$amt');
COMMIT;
SQL
            )
            local rc=$?
            set -e
            if [ "$rc" -eq 0 ]; then committed=$((committed + 1)); break; fi
            # A retryable conflict is expected under contention and is retried. Anything else --
            # a wrong value, a domain error, a type refusal -- is a real failure and is reported.
            if printf '%s' "$out" | grep -qiE "$RETRYABLE"; then
                retries=$((retries + 1)); sleep 0.$((RANDOM % 3 + 1)); continue
            fi
            echo "worker $w: NON-RETRYABLE failure on attempt $attempt: $(printf '%s' "$out" | head -3 | tr '\n' ' ')" >&2
            return 1
        done
    done
    # The NODE is recorded, not just the counts. This harness printed "on $N nodes" for its whole
    # life while every worker used node 0 -- `local w="$1" node=$((w % N))` evaluated the
    # arithmetic before `w` was bound. Fixing that is not the same as proving it, and an
    # unasserted claim is exactly what let the original one survive.
    echo "$committed $retries $node" > "$WORKDIR/worker-$w.stat"
}

pids=()
for w in $(seq 0 $((WORKERS - 1))); do worker "$w" & pids+=("$!"); done
worker_fail=0
for p in "${pids[@]}"; do wait "$p" || worker_fail=$((worker_fail + 1)); done

committed=0; retries=0; nodes_used=""
# nullglob, so a run where every worker died reports THAT rather than a "no such file" from the
# glob expanding to itself -- the failure above is the interesting one and must not be buried.
shopt -s nullglob
for f in "$WORKDIR"/worker-*.stat; do
    read -r c r node < "$f"
    committed=$((committed + c)); retries=$((retries + r))
    nodes_used="$nodes_used$node"$'\n'
done
shopt -u nullglob
distinct_nodes="$(printf '%s' "$nodes_used" | sort -u | grep -c . || true)"
if [ "$worker_fail" -eq 0 ]; then
    ok "$committed transfers committed across $WORKERS workers on $distinct_nodes node(s) ($retries retryable conflicts retried)"
    # Scheduling may produce no conflict; probe 5 deterministically covers retry.
    [ "$retries" -eq 0 ] && echo "        (no conflicts arose here -- probe 5 forces one, and is what covers the retry path)"
    # With at least one worker per node, require every node to receive traffic.
    want_nodes=$(( WORKERS < N ? WORKERS : N ))
    if [ "$distinct_nodes" -eq "$want_nodes" ]; then
        ok "the workers really did spread: $distinct_nodes distinct node(s) took traffic"
    else
        bad "only $distinct_nodes of $want_nodes node(s) took traffic -- the load is not distributed"
    fi
else
    bad "$worker_fail worker(s) hit a NON-retryable failure"
fi
[ "$committed" -eq $((WORKERS * EACH)) ] \
    || bad "expected $((WORKERS * EACH)) commits, counted $committed"

echo
echo "=== 2. CONSERVATION: the total is unmoved, to the last canonical unit ==="
closing="$(yb_sql 0 -c "$TOTAL_SQL" | tr -d ' ' | sed 's/IDR/IDR /')"
if [ "$closing" = "$opening" ]; then
    ok "closing total $closing == opening total $opening"
else
    bad "MONEY MOVED: opening $opening, closing $closing"
fi

# The independent second check. Balances could conserve while individual legs were lost; the
# ledger's debits and credits cancelling to exactly zero says the legs themselves are all there.
legs="$(yb_sql 0 -c "SELECT sum(delta)::text FROM ledger" | tr -d ' ')"
if [ "$legs" = "0.00" ]; then
    ok "every debit has its credit: the ledger sums to $legs"
else
    bad "the ledger legs do not cancel: $legs"
fi
legcount="$(yb_sql 0 -c "SELECT count(*) FROM ledger" | tr -d ' ')"
if [ "$legcount" -eq $((committed * 2)) ]; then
    ok "$legcount ledger legs == 2 x $committed commits"
else
    bad "$legcount ledger legs, expected $((committed * 2))"
fi

echo
echo "=== 3. no torn payload: every balance is still a well-formed value ==="
# A torn 16-byte write would most likely survive as units that are out of domain
# or simply wrong. Re-parsing every rendered balance through the input function
# catches both; the currency cannot be wrong -- the column's type carries it.
torn="$(yb_sql 0 -c "SELECT count(*) FROM account WHERE balance::text::kmoney_idr <> balance" | tr -d ' ')"
if [ "$torn" = "0" ]; then
    ok "all $ACCOUNTS balances re-parse to themselves"
else
    bad "$torn balance(s) do not survive a text round trip"
fi

echo
echo "=== 4. ABORT leaves nothing behind ==="
before="$(yb_sql 0 -c "SELECT balance::text FROM account WHERE id = 1" | tr -d ' ')"
yb_sql 0 <<'SQL' >/dev/null
BEGIN;
UPDATE account SET balance = balance + 'IDR 999.00'::kmoney_idr WHERE id = 1;
ROLLBACK;
SQL
after="$(yb_sql 0 -c "SELECT balance::text FROM account WHERE id = 1" | tr -d ' ')"
if [ "$before" = "$after" ]; then
    ok "rolled-back transfer left the balance at $after"
else
    bad "ROLLBACK changed the balance: $before -> $after"
fi

echo
echo "=== 5. POSITIVE CONTROL: a forced conflict MUST produce a retryable error ==="
# Without this, probe 1 is unfalsifiable: a run that happened to serialize everything cleanly
# would report "conservation held under concurrency" while never having exercised the conflict
# path at all. Two SERIALIZABLE sessions are made to contend on one row on purpose, and NOT
# getting an error is the failure.
yb_sql 0 -c "CREATE TABLE contended (id int PRIMARY KEY, balance kmoney_idr)" >/dev/null
yb_sql 0 -c "INSERT INTO contended VALUES (1, 'IDR 100.00'), (2, 'IDR 100.00')" >/dev/null

# WRITE SKEW, which is the one shape that cannot be resolved by waiting.
#
# Two earlier attempts at this probe failed to produce any error, and both failures were
# informative rather than annoying:
#
#   * two sessions both UPDATE the same row      -> YugabyteDB makes the second WAIT, then succeed
#   * one reads, sleeps, writes; the other writes -> same: the wait queue serializes them
#
# Waiting is correct behaviour and proves nothing about the retry path. So this crosses them:
#
#   A: BEGIN SERIALIZABLE; READ row 1; sleep; WRITE row 2; COMMIT
#   B: BEGIN SERIALIZABLE; READ row 2; sleep; WRITE row 1; COMMIT   (started simultaneously)
#
# Both reads complete before either write, and SERIALIZABLE takes read locks -- so A's write blocks
# on B's read lock while B's write blocks on A's. Neither can wait its way out, and one MUST be
# refused. Not getting a retryable error here is the failure.
conflict_seen=0
applied=0
for round in 1 2 3; do
    : > "$WORKDIR/conflict-a.log"; : > "$WORKDIR/conflict-b.log"
    # Streams merged INSIDE the container, as everywhere else that captures ysqlsh output: `docker
    # exec` multiplexes stdout and stderr separately, so a host-side `2>&1` is interleaving two
    # channels whose relative order was already lost. This log is only grepped for a PATTERN, not
    # diffed, so the ordering failure that broke `yb-ab` cannot break it -- but a frame boundary
    # landing mid-line could still splice one stream's partial line onto the other's, and
    # `grep -qiE '^ERROR'` would then miss a real refusal and report the conflict probe as having
    # produced nothing. Same one-line fix as run-yb.sh; no reason for this to be the exception.
    (
      docker exec -i "${YB_NODES[0]}" bash -c \
        'exec bin/ysqlsh -h "$1" -U yugabyte -X -q -t -A 2>&1' ysqlsh "${YB_HOSTS[0]}" \
        <<'SQL' > "$WORKDIR/conflict-a.log"
BEGIN ISOLATION LEVEL SERIALIZABLE;
SELECT balance::text FROM contended WHERE id = 1;
SELECT pg_sleep(2);
UPDATE contended SET balance = balance + 'IDR 1.00'::kmoney_idr WHERE id = 2;
COMMIT;
SQL
    ) &
    (
      docker exec -i "${YB_NODES[0]}" bash -c \
        'exec bin/ysqlsh -h "$1" -U yugabyte -X -q -t -A 2>&1' ysqlsh "${YB_HOSTS[0]}" \
        <<'SQL' > "$WORKDIR/conflict-b.log"
BEGIN ISOLATION LEVEL SERIALIZABLE;
SELECT balance::text FROM contended WHERE id = 2;
SELECT pg_sleep(2);
UPDATE contended SET balance = balance + 'IDR 1.00'::kmoney_idr WHERE id = 1;
COMMIT;
SQL
    ) &
    wait

    # Count what actually landed, per session, so the closing assertion is derived from THIS run
    # rather than from an assumption about how many rounds conflicted.
    for side in a b; do
        grep -qiE '^ERROR' "$WORKDIR/conflict-$side.log" || applied=$((applied + 1))
    done
    if grep -qiE "$RETRYABLE" "$WORKDIR/conflict-a.log" "$WORKDIR/conflict-b.log"; then
        conflict_seen=1
        printf '        (round %s produced: %s)\n' "$round" \
            "$(grep -hiE 'ERROR' "$WORKDIR/conflict-a.log" "$WORKDIR/conflict-b.log" | head -1)"
        break
    fi
done
if [ "$conflict_seen" -eq 1 ]; then
    ok "forced SERIALIZABLE read-write contention produced a retryable error, so probe 1's retry path is real"
else
    bad "three rounds of deliberate SERIALIZABLE read-write contention produced NO retryable error -- the conflict path is untested, so 'conservation under concurrency' above is not evidence about it"
fi
# THE PART THAT MATTERS EVEN WHEN THE CONFLICT PROBE PASSES: a refused transaction must have moved
# NO money, and an accepted one must have moved exactly its own. The two rows together must hold
# exactly one dollar per session that did not report an error -- so a transaction that was aborted
# after its UPDATE but before its COMMIT shows up here as a total that is too high.
expect="$((200 + applied)).00"
cval="$(yb_sql 0 -c "SELECT sum(balance)::text FROM contended" | tr -d ' ')"
if [ "$cval" = "$expect" ]; then
    ok "the contended rows total $cval -- exactly the $applied session(s) that committed, no more"
else
    bad "the contended rows total $cval but $applied session(s) committed, so it should be $expect"
fi

echo
if [ "$fail" -eq 0 ]; then
    echo "run-yb-concurrent: OK -- $committed concurrent double-entry transfers on a ${N}-node cluster,"
    echo "                   conservation exact ($closing), $retries conflicts retried, retry path proven live."
else
    echo "run-yb-concurrent: FAILED -- $fail probe(s)" >&2
    exit 1
fi
