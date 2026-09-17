#!/usr/bin/env bash
# Long-running concurrent double-entry traffic, asserting conservation throughout.
#
#   kamu-money-pg/yb/run-yb-soak.sh [minutes] [yb-image] [artifact-dir]
#
# Unlike the bounded concurrent suite, this run looks for cumulative failures: slow unit loss,
# long-lived backend allocation growth, and tablet changes under sustained writes.
#
# Check conservation every round so the first failing interval is known.
#
# Logs live under `kamu-money-pg/yb/out/soak/`, not ephemeral `/tmp`.
#
# The default duration is a smoke run. A real soak is `just yb-soak 120` or longer, on purpose, by
# someone who means it. POSITIONAL -- `just` has no name=value call syntax, and `minutes=120` would
# be passed through as a literal string.
set -euo pipefail
cd "$(dirname "$0")/../.."   # repo root

# Lock before touching the shared default run root. A distinct `KMONEY_RUN_ROOT` isolates a run;
# descendants of the release gate inherit the descriptor and re-enter.
# shellcheck source=kamu-money-pg/yb/workspace-lock.sh
source ./kamu-money-pg/yb/workspace-lock.sh
workspace_lock "$(basename "$0")" || exit 1

MINUTES="${1:-3}"
YB_IMAGE="${2:-$(./kamu-money-pg/yb/yb-image.sh)}"
RUN_ROOT="${KMONEY_RUN_ROOT:-kamu-money-pg/yb/out}"
ART="${3:-$RUN_ROOT}"
WORKERS=6
ACCOUNTS=12
SEED_EACH="IDR 10000.00"
N=3

# shellcheck source=kamu-money-pg/yb/cluster.sh
source ./kamu-money-pg/yb/cluster.sh

OUT="$RUN_ROOT/soak"
mkdir -p "$OUT"
LOG="$OUT/soak.log"
: > "$LOG"
say() { printf '%s\n' "$*" | tee -a "$LOG"; }

yb_cluster_up "$N" "$YB_IMAGE"
yb_install_extension_on_all "$ART"
yb_sql 0 -c 'CREATE EXTENSION kmoney' >/dev/null

yb_sql 0 -c "CREATE TABLE account (id int PRIMARY KEY, balance kmoney_idr) SPLIT INTO 6 TABLETS" >/dev/null
yb_sql 0 -c "INSERT INTO account SELECT g, '$SEED_EACH'::kmoney_idr FROM generate_series(1, $ACCOUNTS) g" >/dev/null

# Exercise the row aggregate every fifteen seconds against a table under concurrent writes, matching
# the shape of a reconciliation query.
TOTAL_SQL="SELECT sum(balance)::text FROM account"
OPENING="$(yb_sql 0 -c "$TOTAL_SQL" | tr -d ' ')"

say "kmoney_idr soak on YugabyteDB"
say "image     $YB_IMAGE"
say "cluster   $N nodes RF=3, $WORKERS workers, $ACCOUNTS accounts"
say "duration  ${MINUTES} minute(s)"
say "opening   $OPENING"
say ""

# The round budget is wall-clock, taken from the SERVER so the shell's own clock (and the fact
# that Date.now-style helpers are unavailable in some harnesses) never enters the measurement.
now_epoch() { yb_sql 0 -c "SELECT extract(epoch FROM now())::bigint" | tr -d ' '; }
START="$(now_epoch)"
DEADLINE=$((START + MINUTES * 60))

# One worker: transfer between two accounts inside one distributed transaction, retrying only a
# retryable conflict. Runs until the deadline; a non-retryable failure stops everything, because
# the interesting soak result is the FIRST divergence, not how many followed it.
soak_worker() {
    # TWO `local`s, and this is not a style choice. Bash expands every word on a command line
    # BEFORE running it, so in `local w="$1" node=$((w % N))` the arithmetic ran while `w` was
    # still unset -- `node` was 0 for EVERY worker, and this soak spent its life driving one node
    # of a three-node cluster while reporting otherwise. ShellCheck SC2318 names it.
    local w="$1"
    local node=$((w % N))
    # ATTEMPTED IS NOT COMMITTED, and conflating them is how this script could pass having written
    # nothing. `attempted` counted transfers, the retry loop fell out silently after its tenth
    # failure, and the total was then trivially conserved because no row had moved. Four counters,
    # because four different things happened.
    local attempted=0 committed=0 retried=0 from to amt out rc
    while [ "$(now_epoch)" -lt "$DEADLINE" ]; do
        attempted=$((attempted + 1))
        from=$(( (w * 7 + attempted * 3) % ACCOUNTS + 1 ))
        to=$(( (w * 5 + attempted * 11) % ACCOUNTS + 1 ))
        [ "$from" = "$to" ] && to=$(( to % ACCOUNTS + 1 ))
        amt="IDR 0.$(printf '%02d' $(( (attempted * 13 + w) % 97 + 1 )))000000000000001"
        local attempt exhausted=1
        for attempt in 1 2 3 4 5 6 7 8 9 10; do
            set +e
            # Merged inside the container, as in run-yb-concurrent.sh: `out` classifies the
            # failure, and a soak runs this often enough that a one-in-N stream race would be
            # observed as an unexplained breach hours in.
            out=$(docker exec -i "${YB_NODES[$node]}" bash -c \
                    'exec bin/ysqlsh -h "$1" -U yugabyte -X -q -t -A -v ON_ERROR_STOP=1 2>&1' \
                    ysqlsh "${YB_HOSTS[$node]}" <<SQL
BEGIN;
UPDATE account SET balance = balance - '$amt'::kmoney_idr WHERE id = $from;
UPDATE account SET balance = balance + '$amt'::kmoney_idr WHERE id = $to;
COMMIT;
SQL
            ); rc=$?
            set -e
            if [ "$rc" -eq 0 ]; then
                committed=$((committed + 1)); exhausted=0; break
            fi
            # cluster.sh owns the retry classifier shared by all concurrent suites.
            if printf '%s' "$out" | grep -qiE "$YB_RETRYABLE"; then
                retried=$((retried + 1)); sleep 0.$((RANDOM % 3 + 1)); continue
            fi
            echo "soak worker $w: NON-RETRYABLE: $(printf '%s' "$out" | head -2 | tr '\n' ' ')" >&2
            printf '%s %s %s\n' "$attempted" "$committed" "$retried" > "$OUT/worker-$w.stat"
            return 1
        done
        # Exhausting the retry budget is a failed transfer, not a successful no-op.
        if [ "$exhausted" -eq 1 ]; then
            echo "soak worker $w: RETRY BUDGET EXHAUSTED after $attempt attempts: $(printf '%s' "$out" | head -2 | tr '\n' ' ')" >&2
            printf '%s %s %s\n' "$attempted" "$committed" "$retried" > "$OUT/worker-$w.stat"
            return 1
        fi
    done
    printf '%s %s %s\n' "$attempted" "$committed" "$retried" > "$OUT/worker-$w.stat"
}

pids=()
for w in $(seq 0 $((WORKERS - 1))); do soak_worker "$w" & pids+=("$!"); done

# Watch conservation while they run. This is the actual soak assertion; the workers are only the
# load. A round that diverges stops the run immediately, with the round number and the totals.
round=0
breaches=0
while [ "$(now_epoch)" -lt "$DEADLINE" ]; do
    sleep 15
    round=$((round + 1))
    total="$(yb_sql 0 -c "$TOTAL_SQL" 2>/dev/null | tr -d ' ' || echo UNREADABLE)"
    rows="$(yb_sql 0 -c "SELECT count(*) FROM account" 2>/dev/null | tr -d ' ' || echo '?')"
    # Every balance must still re-parse to itself: a torn 16-byte payload is the failure mode a
    # long run is most likely to surface, and a total that happens to still add up would not
    # necessarily reveal it.
    torn="$(yb_sql 0 -c "SELECT count(*) FROM account WHERE balance::text::kmoney_idr <> balance" 2>/dev/null | tr -d ' ' || echo '?')"
    if [ "$total" = "$OPENING" ] && [ "$rows" = "$ACCOUNTS" ] && [ "$torn" = "0" ]; then
        say "round $round  $(( $(now_epoch) - START ))s  total=$total rows=$rows torn=0  OK"
    else
        say "round $round  $(( $(now_epoch) - START ))s  total=$total rows=$rows torn=$torn  BREACH (opening $OPENING)"
        breaches=$((breaches + 1))
        break
    fi
done

worker_fail=0
for p in "${pids[@]}"; do wait "$p" || worker_fail=$((worker_fail + 1)); done

attempted=0
committed=0
retried=0
# nullglob, so a run where every worker died reports THAT rather than a "no such file" from the
# glob expanding to itself.
shopt -s nullglob
for f in "$OUT"/worker-*.stat; do
    read -r a c r < "$f"
    attempted=$((attempted + a)); committed=$((committed + c)); retried=$((retried + r))
done
shopt -u nullglob

CLOSING="$(yb_sql 0 -c "$TOTAL_SQL" | tr -d ' ')"
say ""
say "attempted  $attempted"
say "committed  $committed"
say "retried    $retried"
say "rounds     $round"
say "closing    $CLOSING"

# CONSERVATION IS NOT ENOUGH, and on its own it is nearly vacuous: a soak that committed NOTHING
# conserves perfectly. So the run must also prove it did work. One committed transfer per worker
# per round is a deliberately low bar -- this is a liveness floor, not a throughput threshold, and
# a threshold invented without a baseline either never fires or fires on somebody else's hardware.
MIN_COMMITTED=$(( WORKERS * round ))
if [ "$breaches" -eq 0 ] && [ "$worker_fail" -eq 0 ] && [ "$CLOSING" = "$OPENING" ] \
   && [ "$committed" -ge "$MIN_COMMITTED" ] && [ "$committed" -gt 0 ]; then
    say "soak: OK -- conservation held for every one of $round checks across $committed COMMITTED transfers"
else
    say "soak: FAILED -- breaches=$breaches worker_failures=$worker_fail closing=$CLOSING opening=$OPENING"
    if [ "$committed" -lt "$MIN_COMMITTED" ]; then
        say "soak: committed $committed transfers, expected at least $MIN_COMMITTED --"
        say "soak: a conserved total across no committed work proves nothing."
    fi
    exit 1
fi
