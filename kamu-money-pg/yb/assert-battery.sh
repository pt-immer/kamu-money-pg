#!/usr/bin/env bash
# Fail-closed oracle for the ABI battery.
#
# `yb-ab` diffs the YugabyteDB output against the stock-PG15 output. That proves the two engines
# produced the SAME bytes. It cannot prove they produced the RIGHT bytes, or that either one ran
# the experiment: two identical early failures, two empty files, or two matching truncated
# outputs all satisfy a diff. Worse, a kamu-money-pg SOURCE regression changes BOTH outputs
# identically, so the diff is structurally blind to it and this oracle is the only defence.
#
# An expected-error battery legitimately cannot use ON_ERROR_STOP=1 -- several probes exist to
# provoke errors whose TEXT is part of what must match. So the battery needs an EXTERNAL oracle
# instead. Equality only means something once both sides pass this.
#
# Usage: assert-battery.sh <output-file> <label> <client-exit-status>
#        assert-battery.sh --list          # print the assertion table (used by the selftest)
set -euo pipefail

# ---------------------------------------------------------------------------------------------
# THE ASSERTION TABLE.
#
# One list, consumed BOTH by the checker below and by hygiene/tests/assert_battery.rs through
# `--list`. That coupling keeps the self-test synchronized with the production oracle.
# hard-coded its own mutations, covered 6 of 10 assertions, and still printed "every assertion
# still bites". Driving the control from this table means an assertion added here is negatively
# controlled automatically, by construction rather than by remembering.
#
# Fields: MODE %%% PATTERN %%% EXPECTED %%% DESCRIPTION   (%%% cannot occur in SQL output)
#   F  fixed-string match (grep -F). Preferred: no escaping, no column-width fragility.
#   E  extended regex (grep -E). Only where a fixed substring would be ambiguous.
#   H  header -> value: the line matching PATTERN must be followed 2 lines later by EXPECTED
#      (psql renders `header`, `-----`, `value`). For one-column results whose value alone
#      ("t", "2") is far too generic to pin on its own.
#
# Values, not shapes. Each assertion names the exact semantic value it protects.
# because it asserted `18 |` (a width) rather than the payload, and never asserted the arithmetic
# results at all.
# ---------------------------------------------------------------------------------------------
assertion_table() {
    cat <<'TABLE'
F%%%10.50 | 10.50      | 16000.01 | 10.5 | 10.500 | -0.000000000000000001 | 999999999999999999.999999999999999999%%%%%%s1 text round-trip across every exponent class, incl. the tagged form, the domain top and one canonical unit
F%%%16 |             18 | 000064a7b3b6e00d0000000000000000%%%%%%s2 send() widths AND the exact 16 payload bytes for USD 1.00
E%%%^ +3 \| t *$%%%%%%s2b pinned COPY BINARY round trip: rows_recv = 3, roundtrip_exact = t
H%%%mixed_roundtrip_exact%%%t%%%s2b mixed COPY BINARY round trip survives send -> recv
F%%%10.75 | 10.25%%%%%%s3 same-currency + and - results
H%%%agg_across_a_domain_edge%%%999999999999999999.999999999999999999%%%s4 sum() totals a column across a partial sum outside the stored-value domain
H%%%empty_is_null%%%t%%%s4 sum() over no rows is NULL, never a zero
E%%%^ *3\.333333333333333334 \| 3\.333333333333333333 \| 3\.333333333333333333 *$%%%%%%s5 allocate even split, odd unit on the first share
E%%%^ *0\.00 \| 0\.000000000000000001 \| 0\.00 *$%%%%%%s5 allocate zero-weight guard
E%%%^ *0\.000000000000000002 \| 0\.000000000000000002 \| 0\.000000000000000004 *$%%%%%%s5 allocate remainder scheme: leftover units to the FIRST positive-weight shares
H%%%conserves%%%16000.01%%%s5 allocation conserves the total exactly
E%%%^ t  \| t *$%%%%%%s6 comparison predicates: lt, ge
H%%%usd_ones%%%2%%%s6 equality predicate selectivity over a pinned column
E%%%^ *702888007 \| -1388235877 \| -129968833 \| 1671845669 *$%%%%%%s7 pinned hash values -- the sharpest ABI signal
H%%%same_logical_same_hash%%%t%%%s7 the pinned and mixed hashes agree on one logical amount
H%%%mixed_cross_eq_false%%%f%%%s8 kmoney_mixed cross-currency equality is false, not an error
H%%%mixed_usd_ones%%%2%%%s8 equality predicate selectivity over a mixed column
F%%%operator does not exist: kmoney_usd + kmoney_idr%%%%%%refusal: cross-currency addition cannot parse, 42883
F%%%operator does not exist: kmoney_idr > kmoney_usd%%%%%%refusal: cross-currency ordering cannot parse, 42883
F%%%function sum(kmoney_mixed) does not exist%%%%%%refusal: no sum(kmoney_mixed) aggregate
F%%%canonical units is outside the supported range%%%%%%refusal: one past the domain top
F%%%fractional digits exceeds the supported scale of 18%%%%%%refusal: excess precision, refused not rounded
F%%%kmoney_usd: expected USD, got IDR%%%%%%refusal: a well-formed value of the WRONG currency is refused at input
TABLE
}

if [ "${1:-}" = "--list" ]; then
    assertion_table
    exit 0
fi

OUT="${1:?usage: assert-battery.sh <output-file> <label> <client-exit-status>}"
LABEL="${2:?usage: assert-battery.sh <output-file> <label> <client-exit-status>}"
# No default. This parameter proves that the client did not
# die; defaulting it to 0 would mean a caller who forgot to pass it silently asserts "nothing
# broke" -- the exact assumption the whole script exists to stop making.
STATUS="${3:?client exit status is required -- pass the captured status, never assume 0}"

fail() { echo "battery-assert[$LABEL]: FAIL -- $*" >&2; exit 1; }

[ -s "$OUT" ] || fail "output file missing or empty: $OUT"

# Under ON_ERROR_STOP=0 an EXPECTED SQL error does not set the client's status, so a nonzero one
# is structural: could not connect, file not found, backend died.
[ "$STATUS" -eq 0 ] || fail "client exited $STATUS; under ON_ERROR_STOP=0 that is a structural failure, not an expected SQL error"

# Reached the end, EXACTLY once. "At least once" would accept a file holding two half-batteries.
complete="$(grep -c '^== BATTERY COMPLETE ==$' "$OUT" || true)"
[ "$complete" = "1" ] || fail "expected exactly 1 '== BATTERY COMPLETE ==', found $complete"

while IFS= read -r row; do
    [ -n "$row" ] || continue
    mode="${row%%\%\%\%*}"; rest="${row#*%%%}"
    pat="${rest%%\%\%\%*}";  rest="${rest#*%%%}"
    want="${rest%%\%\%\%*}"; desc="${rest#*%%%}"
    case "$mode" in
        F) grep -qF -- "$pat" "$OUT" || fail "$desc — missing: $pat" ;;
        E) grep -Eq -- "$pat" "$OUT" || fail "$desc — no line matched: $pat" ;;
        H)
            # The `|| true` is load-bearing: under `set -o pipefail` a non-matching grep makes
            # the whole pipeline return 1, the assignment fails, and `set -e` kills this script
            # with NO message -- so a missing header would exit nonzero while reporting nothing,
            # and every caller would see a failure it cannot explain. Caught by the selftest's
            # failed-for-the-wrong-reason check on its first run.
            block="$(grep -A2 -F -- "$pat" "$OUT" || true)"
            got="$(printf '%s\n' "$block" | tail -1 | sed 's/^ *//; s/ *$//')"
            [ "$got" = "$want" ] || fail "$desc — expected '$want' under '$pat', got '$got'"
            ;;
        *) fail "malformed assertion table row: $row" ;;
    esac
done < <(assertion_table)

n="$(assertion_table | grep -c . )"
echo "battery-assert[$LABEL]: OK (complete once, $n table assertions passed, client status 0)"
