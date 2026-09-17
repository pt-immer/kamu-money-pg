-- 10-hash: the persisted stable hash, pinned to exact values.
--
-- Ports: the_persisted_hash_values_are_pinned_not_merely_consistent,
-- a_pinned_value_hashes_as_the_erased_one_does.
\pset pager off
\pset footer off
\pset format unaligned
\pset tuples_only on
\pset null '<NULL>'
\set VERBOSITY terse
SET client_min_messages = error;
CREATE EXTENSION IF NOT EXISTS kmoney;

\echo -- the_persisted_hash_values_are_pinned_not_merely_consistent
SELECT kmoney_usd_hash('0.00'::kmoney_usd);
SELECT kmoney_usd_hash('1.00'::kmoney_usd);
SELECT kmoney_idr_hash('1.00'::kmoney_idr);
SELECT kmoney_usd_hash('-1.00'::kmoney_usd);

\echo -- a_pinned_value_hashes_as_the_erased_one_does
SELECT 'pinned_hash=mixed_hash=' ||
    (kmoney_usd_hash('10.50'::kmoney_usd) = kmoney_mixed_hash('USD 10.50'::kmoney_mixed));

\echo == CASE COMPLETE: 10-hash ==
