-- 11-compare: total ordering within a currency; none across, and no numeric bridge.
--
-- Ports: there_is_no_cast_to_numeric, pinned_ordering_needs_no_currency_check,
-- cross_currency_ordering_has_no_operator.
\pset pager off
\pset footer off
\pset format unaligned
\pset tuples_only on
\pset null '<NULL>'
\set VERBOSITY terse
SET client_min_messages = error;
CREATE EXTENSION IF NOT EXISTS kmoney;

\echo -- pinned_ordering_needs_no_currency_check
SELECT 'ordered=' || ('1.00'::kmoney_usd < '2.00'::kmoney_usd);

\echo -- cross_currency_ordering_has_no_operator
SELECT '1.00'::kmoney_usd < '1.00'::kmoney_idr;

\echo -- there_is_no_cast_to_numeric
SELECT ('1.00'::kmoney_usd)::numeric::text;

\echo == CASE COMPLETE: 11-compare ==
