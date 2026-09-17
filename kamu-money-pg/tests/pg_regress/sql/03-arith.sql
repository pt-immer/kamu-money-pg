-- 03-arith: exact arithmetic within a currency; no operator across currencies.
--
-- Ports: addition_is_exact_at_one_unit_of_the_eighteenth_decimal,
-- addition_past_the_domain_top_is_refused, pinned_arithmetic_stays_within_the_currency,
-- cross_currency_arithmetic_has_no_operator.
\pset pager off
\pset footer off
\pset format unaligned
\pset tuples_only on
\pset null '<NULL>'
\set VERBOSITY terse
SET client_min_messages = error;
CREATE EXTENSION IF NOT EXISTS kmoney;

\echo -- addition_is_exact_at_one_unit_of_the_eighteenth_decimal
SELECT ('0.000000000000000001'::kmoney_usd + '0.000000000000000002'::kmoney_usd)::text;

\echo -- addition_past_the_domain_top_is_refused
SELECT ('999999999999999999.999999999999999999'::kmoney_idr + '0.000000000000000001'::kmoney_idr)::text;

\echo -- pinned_arithmetic_stays_within_the_currency
SELECT ('1.25'::kmoney_usd + '2.75'::kmoney_usd)::text;

\echo -- cross_currency_arithmetic_has_no_operator
-- Fails while the query is parsed: there is no operator to resolve.
SELECT ('1.00'::kmoney_usd + '1.00'::kmoney_idr)::text;

\echo == CASE COMPLETE: 03-arith ==
