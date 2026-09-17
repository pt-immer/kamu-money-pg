-- 04-sum: the per-currency aggregate, driven by hand where plans would vary.
--
-- Ports: sum_totals_a_pinned_column, sum_of_no_rows_is_null, every_pinned_type_has_its_own_sum,
-- the_sum_aggregate_is_plan_independent_across_a_domain_edge_transient,
-- the_sum_aggregate_combines_an_empty_partial, the_sum_aggregate_rejects_a_forged_transition_state,
-- the_sum_aggregate_rejects_a_total_that_leaves_the_domain.
\pset pager off
\pset footer off
\pset format unaligned
\pset tuples_only on
\pset null '<NULL>'
\set VERBOSITY terse
SET client_min_messages = error;
CREATE EXTENSION IF NOT EXISTS kmoney;

\echo -- sum_totals_a_pinned_column
CREATE TEMP TABLE ledger (amount kmoney_usd);
INSERT INTO ledger VALUES ('1.25'), ('2.75'), ('6.00');
SELECT sum(amount)::text FROM ledger;

\echo -- sum_of_no_rows_is_null
CREATE TEMP TABLE empty_ledger (amount kmoney_usd);
SELECT 'empty_sum_is_null=' || (sum(amount) IS NULL) FROM empty_ledger;

\echo -- every_pinned_type_has_its_own_sum
SELECT 'sum_aggregates=' || count(*) FROM pg_aggregate a
  JOIN pg_proc p ON p.oid = a.aggfnoid
  JOIN pg_type t ON t.oid = p.prorettype
 WHERE p.proname = 'sum' AND t.typlen = 16 AND t.typname LIKE 'kmoney\_%';

\echo -- the_sum_aggregate_is_plan_independent_across_a_domain_edge_transient
CREATE TEMP TABLE edge (position int, amount kmoney_usd);
INSERT INTO edge VALUES
    (1, '999999999999999999.999999999999999999'),
    (2, '999999999999999999.999999999999999999'),
    (3, '-999999999999999999.999999999999999999');
SELECT sum(amount)::text FROM (SELECT amount FROM edge ORDER BY position) ordered;
SELECT sum(amount)::text FROM (SELECT amount FROM edge ORDER BY position DESC) ordered;

\echo -- the_sum_aggregate_combines_an_empty_partial
SELECT 'empty_partial_is_identity=' ||
    (kmoney_usd_sum_final(kmoney_usd_sum_combine(NULL, kmoney_usd_sum_accum(NULL, '1.25'::kmoney_usd)))::text = '1.25');

\echo -- the_sum_aggregate_rejects_a_forged_transition_state
SELECT kmoney_usd_sum_final('\x0102030405'::bytea)::text;

\echo -- the_sum_aggregate_rejects_a_total_that_leaves_the_domain
CREATE TEMP TABLE overflowing (amount kmoney_usd);
INSERT INTO overflowing VALUES
    ('999999999999999999.999999999999999999'), ('0.000000000000000001');
SELECT sum(amount)::text FROM overflowing;

-- The refusal above narrows to i128 and reports the total as an i128. 171 rows
-- at the domain edge exceed i128 itself, which is the only path that reaches
-- the wide arm; 170 still narrow, so 171 is the threshold, not a round number.
\echo -- the_sum_aggregate_reports_a_total_too_wide_for_i128
CREATE TEMP TABLE too_wide (amount kmoney_usd);
INSERT INTO too_wide
    SELECT '999999999999999999.999999999999999999'::kmoney_usd FROM generate_series(1, 171);
SELECT sum(amount)::text FROM too_wide;

\echo == CASE COMPLETE: 04-sum ==
