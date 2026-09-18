-- 01-layout: the physical shape of both families, and the space argument stated honestly.
--
-- Ports: kmoney_mixed_is_eighteen_bytes_with_no_header, a_pinned_value_is_sixteen_bytes,
-- the_catalog_says_fixed_length_plain_and_byte_aligned,
-- the_size_tradeoff_against_numeric_is_measured_not_assumed,
-- the_size_does_not_depend_on_the_value, numeric_silently_rounds_four_e_minus_nineteen_to_zero,
-- every_iso_code_has_a_type, no_generated_type_carries_an_operator_class.
--
-- OUTPUT IS UNALIGNED AND TUPLES-ONLY throughout this suite, on purpose: psql's aligned table
-- rendering pads every column to its widest cell, so a golden file would encode column WIDTHS
-- as well as values and a one-character change in an unrelated row would move them.
\pset pager off
\pset footer off
\pset format unaligned
\pset tuples_only on
\pset null '<NULL>'
\set VERBOSITY terse
SET client_min_messages = error;
CREATE EXTENSION IF NOT EXISTS kmoney;

\echo -- kmoney_mixed_is_eighteen_bytes_with_no_header
CREATE TEMP TABLE sized (v kmoney_mixed);
INSERT INTO sized VALUES ('USD 10.50');
SELECT 'stored=' || pg_column_size(v)
    || ' in_memory=' || pg_column_size('USD 10.50'::kmoney_mixed) FROM sized;

\echo -- a_pinned_value_is_sixteen_bytes
-- The currency left the value, so the pinned payload is two bytes narrower than
-- the erased one still carrying its ISO code.
SELECT 'pinned=' || pg_column_size('10.50'::kmoney_usd)
    || ' erased=' || pg_column_size('USD 10.50'::kmoney_mixed);

\echo -- the_catalog_says_fixed_length_plain_and_byte_aligned
SELECT format('%s=%s/%s/%s/%s', typname, typlen, typbyval, typalign, typstorage)
  FROM pg_type WHERE typname IN ('kmoney_mixed', 'kmoney_usd') ORDER BY typname;

\echo -- the_size_tradeoff_against_numeric_is_measured_not_assumed
CREATE TEMP TABLE compared (r kmoney_usd, n numeric(36,18));
INSERT INTO compared VALUES
    ('10.50', 10.50),
    ('999999999999999999.999999999999999999', 999999999999999999.999999999999999999);
-- The RELATIONS are asserted, not numeric's exact widths: the pinned type stays
-- fixed at 16 while numeric wins on a typical amount and loses at the top.
SELECT 'kmoney_usd_fixed_at_16=' || (count(DISTINCT pg_column_size(r)) = 1 AND max(pg_column_size(r)) = 16)
    || ' numeric_wins_typical=' || (min(pg_column_size(n)) < 16)
    || ' numeric_loses_at_top=' || (max(pg_column_size(n)) > 16)
  FROM compared;

\echo -- the_size_does_not_depend_on_the_value
CREATE TEMP TABLE varied (v kmoney_mixed);
INSERT INTO varied VALUES
    ('USD 0.00'), ('USD 10.50'), ('IDR 999999999999999999.999999999999999999'), ('JPY -1');
SELECT 'distinct_sizes=' || count(DISTINCT pg_column_size(v)) FROM varied;

\echo -- numeric_silently_rounds_four_e_minus_nineteen_to_zero
-- PostgreSQL numeric rounds this silently; 02-text asserts that the pinned type refuses it.
SELECT 'numeric_rounds_4e_minus_19_to_zero=' || ('0.0000000000000000004'::numeric(36,18) = 0);

\echo -- every_iso_code_has_a_type
SELECT 'pinned_type_count=' || count(*) FROM pg_type WHERE typname LIKE 'kmoney\_%' AND typlen = 16;

\echo -- no_generated_type_carries_an_operator_class
-- The absent operator class is what keeps these types byte-exact on YugabyteDB.
-- The first term proves the predicate matched every generated type, so the zero
-- cannot be the zero of an empty match.
SELECT 'inspected=' || (SELECT count(*) FROM pg_type WHERE typname LIKE 'kmoney\_%' AND typlen = 16)
    || ' opclasses=' || (SELECT count(*) FROM pg_opclass WHERE opcintype IN
        (SELECT oid FROM pg_type WHERE typname LIKE 'kmoney\_%' AND typlen = 16));

\echo == CASE COMPLETE: 01-layout ==
