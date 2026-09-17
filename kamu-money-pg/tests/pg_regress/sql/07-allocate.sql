-- 07-allocate: conserving distribution, exact at canonical units.
--
-- Ports: allocation_conserves_the_pinned_total, allocation_honours_weights_and_still_conserves,
-- a_negative_amount_allocates_by_the_same_scheme,
-- allocation_never_pays_a_zero_weight_recipient, allocation_refuses_a_null_weight,
-- allocation_refuses_weights_that_sum_to_zero.
\pset pager off
\pset footer off
\pset format unaligned
\pset tuples_only on
\pset null '<NULL>'
\set VERBOSITY terse
SET client_min_messages = error;
CREATE EXTENSION IF NOT EXISTS kmoney;

\echo -- allocation_conserves_the_pinned_total
SELECT sum(share)::text FROM unnest(kmoney_usd_allocate('10.00'::kmoney_usd, ARRAY[1, 1, 1])) AS share;

\echo -- allocation_honours_weights_and_still_conserves
SELECT string_agg(share::text, ',') FROM unnest(kmoney_usd_allocate('0.10'::kmoney_usd, ARRAY[3, 1, 1])) AS share;
-- The remainder SCHEME is frozen contract: leftover units land on the FIRST
-- positive-weight shares. 8 units over [1,1,3] is [2,2,4] here; Hamilton /
-- largest-remainder would say [2,1,5], and only an inexact division can tell
-- the two apart.
SELECT string_agg(share::text, ',') FROM unnest(kmoney_usd_allocate('0.000000000000000008'::kmoney_usd, ARRAY[1, 1, 3])) AS share;

\echo -- a_negative_amount_allocates_by_the_same_scheme
SELECT string_agg(share::text, ',') FROM unnest(kmoney_usd_allocate('-0.10'::kmoney_usd, ARRAY[3, 1, 1])) AS share;
SELECT string_agg(share::text, ',') FROM unnest(kmoney_usd_allocate('-0.000000000000000008'::kmoney_usd, ARRAY[1, 1, 3])) AS share;

\echo -- allocation_never_pays_a_zero_weight_recipient
SELECT string_agg(share::text, ',') FROM unnest(kmoney_usd_allocate('0.03'::kmoney_usd, ARRAY[1, 0, 1])) AS share;

\echo -- allocation_refuses_a_null_weight
SELECT count(*) FROM unnest(kmoney_usd_allocate('1.00'::kmoney_usd, ARRAY[1, NULL]));

\echo -- allocation_refuses_weights_that_sum_to_zero
SELECT count(*) FROM unnest(kmoney_usd_allocate('1.00'::kmoney_usd, ARRAY[0, 0]));

\echo == CASE COMPLETE: 07-allocate ==
