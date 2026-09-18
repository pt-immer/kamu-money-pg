-- 02-text: canonical text, both directions, both families.
--
-- Ports: the_text_form_matches_money_core, kmoney_refuses_what_numeric_silently_rounds,
-- the_domain_top_round_trips, one_unit_past_the_domain_is_refused,
-- an_unknown_currency_is_refused_at_the_boundary, the_native_type_and_the_text_storage_agree,
-- a_pinned_type_renders_bare, a_pinned_type_accepts_its_own_tag,
-- a_pinned_type_refuses_another_currencys_tag.
\pset pager off
\pset footer off
\pset format unaligned
\pset tuples_only on
\pset null '<NULL>'
\set VERBOSITY terse
SET client_min_messages = error;
CREATE EXTENSION IF NOT EXISTS kmoney;

\echo -- the_text_form_matches_money_core
SELECT 'USD 10.50'::kmoney_mixed::text;
SELECT 'USD 10.5'::kmoney_mixed::text;
SELECT 'JPY 10.5'::kmoney_mixed::text;
SELECT 'KWD 10.5'::kmoney_mixed::text;
SELECT 'USD -0.000000000000000001'::kmoney_mixed::text;

\echo -- kmoney_refuses_what_numeric_silently_rounds
SELECT '0.0000000000000000004'::kmoney_usd::text;

\echo -- the_domain_top_round_trips
SELECT '999999999999999999.999999999999999999'::kmoney_idr::text;

\echo -- one_unit_past_the_domain_is_refused
SELECT '1000000000000000000'::kmoney_idr::text;

\echo -- an_unknown_currency_is_refused_at_the_boundary
SELECT 'ZWL 1.00'::kmoney_mixed::text;

\echo -- the_native_type_and_the_text_storage_agree
CREATE TEMP TABLE both_forms (portable text NOT NULL, native kmoney_mixed NOT NULL);
INSERT INTO both_forms VALUES
    ('USD 10.50', 'USD 10.50'),
    ('JPY 10.5', 'JPY 10.5'),
    ('KWD 10.500', 'KWD 10.500'),
    ('IDR 999999999999999999.999999999999999999', 'IDR 999999999999999999.999999999999999999'),
    ('USD -0.000000000000000001', 'USD -0.000000000000000001'),
    ('XAU 10.5', 'XAU 10.5');
SELECT 'render_disagreements=' || count(*) FROM both_forms WHERE portable <> native::text;
SELECT 'reparse_mismatches=' || count(*) FROM both_forms WHERE portable::kmoney_mixed::text <> native::text;

\echo -- a_pinned_type_renders_bare
SELECT '10.50'::kmoney_usd::text;

\echo -- a_pinned_type_accepts_its_own_tag
SELECT 'USD 10.50'::kmoney_usd::text;

\echo -- a_pinned_type_refuses_another_currencys_tag
SELECT 'IDR 10.50'::kmoney_usd::text;

\echo == CASE COMPLETE: 02-text ==
