-- 12-errors: the SQLSTATE contract. Clients dispatch on the CODE, not the text,
-- so the code each refusal carries is frozen API -- a data error arriving as
-- XX000 would page internal-error monitoring and defeat classification layers.
--
-- Ports: a_wrong_tag_refusal_is_invalid_text_representation,
-- an_out_of_domain_literal_refusal_is_numeric_value_out_of_range,
-- a_forged_sum_state_refusal_is_invalid_binary_representation,
-- a_zero_parts_division_refusal_is_division_by_zero,
-- an_invalid_weights_refusal_is_invalid_parameter_value,
-- a_cross_currency_expression_refusal_is_undefined_function.
--
-- VERBOSITY sqlstate prints each error as its bare five-character code and
-- nothing else, so this golden pins the codes without re-pinning the message
-- texts (02-text and friends own those).
\pset pager off
\pset footer off
\pset format unaligned
\pset tuples_only on
\pset null '<NULL>'
\set VERBOSITY sqlstate
SET client_min_messages = error;
CREATE EXTENSION IF NOT EXISTS kmoney;

\echo -- a_wrong_tag_refusal_is_invalid_text_representation
SELECT 'IDR 1.00'::kmoney_usd;

\echo -- an_out_of_domain_literal_refusal_is_numeric_value_out_of_range
SELECT '1000000000000000000.00'::kmoney_usd;

\echo -- a_forged_sum_state_refusal_is_invalid_binary_representation
SELECT kmoney_usd_sum_final('\x0102030405'::bytea);

\echo -- a_zero_parts_division_refusal_is_division_by_zero
SELECT quotient::text FROM kmoney_usd_div('1.00'::kmoney_usd, 0, 'floor');

\echo -- an_invalid_weights_refusal_is_invalid_parameter_value
SELECT kmoney_usd_allocate('1.00'::kmoney_usd, ARRAY[]::int4[]);

\echo -- a_cross_currency_expression_refusal_is_undefined_function
SELECT '1.00'::kmoney_usd + '1.00'::kmoney_idr;

\echo == CASE COMPLETE: 12-errors ==
