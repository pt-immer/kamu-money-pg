-- 05-mixed: the one deliberately currency-erased type, and the way out of it.
--
-- Ports: a_mixed_column_equality_is_currency_aware_and_never_raises, a_mixed_column_cannot_be_ordered,
-- addition_on_the_mixed_type_does_not_exist_either, a_mixed_column_stores_several_currencies_side_by_side,
-- the_conversion_out_of_mixed_proves_the_currency, the_conversion_out_of_mixed_refuses_the_wrong_currency,
-- sum_on_a_mixed_column_fails_at_plan_time.
\pset pager off
\pset footer off
\pset format unaligned
\pset tuples_only on
\pset null '<NULL>'
\set VERBOSITY terse
SET client_min_messages = error;
CREATE EXTENSION IF NOT EXISTS kmoney;

\echo -- a_mixed_column_equality_is_currency_aware_and_never_raises
CREATE TEMP TABLE wallet (amount kmoney_mixed);
INSERT INTO wallet VALUES ('USD 1.00'), ('IDR 1.00'), ('USD 1.00');
SELECT 'cross_currency_eq=' || ('USD 1.00'::kmoney_mixed = 'IDR 1.00'::kmoney_mixed)
    || ' usd_ones=' || (SELECT count(*) FROM wallet WHERE amount = 'USD 1.00'::kmoney_mixed);

\echo -- a_mixed_column_cannot_be_ordered
SELECT 'USD 1.00'::kmoney_mixed < 'USD 2.00'::kmoney_mixed;

\echo -- addition_on_the_mixed_type_does_not_exist_either
SELECT ('USD 1.00'::kmoney_mixed + 'USD 1.00'::kmoney_mixed)::text;

\echo -- a_mixed_column_stores_several_currencies_side_by_side
SELECT amount::text FROM wallet ORDER BY amount::text;

\echo -- the_conversion_out_of_mixed_proves_the_currency
SELECT ('USD 2.50'::kmoney_mixed)::text::kmoney_usd::text;

\echo -- the_conversion_out_of_mixed_refuses_the_wrong_currency
SELECT ('IDR 2.50'::kmoney_mixed)::text::kmoney_usd::text;

\echo -- sum_on_a_mixed_column_fails_at_plan_time
SELECT sum(amount)::text FROM wallet;

\echo == CASE COMPLETE: 05-mixed ==
