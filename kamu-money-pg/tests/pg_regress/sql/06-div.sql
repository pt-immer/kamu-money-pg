-- 06-div: lossy division names its residue, in one currency by construction.
--
-- Ports: division_conserves_the_pinned_amount, the_division_identity_holds_for_every_rounding_mode,
-- the_residue_is_negative_under_round_up_modes, division_refuses_an_unknown_rounding_mode.
\pset pager off
\pset footer off
\pset format unaligned
\pset tuples_only on
\pset null '<NULL>'
\set VERBOSITY terse
SET client_min_messages = error;
CREATE EXTENSION IF NOT EXISTS kmoney;

\echo -- division_conserves_the_pinned_amount
SELECT quotient::text || ' | ' || residue::text FROM kmoney_usd_div('10.00'::kmoney_usd, 3, 'toward_zero');
SELECT 'rebuilt=' || (q.quotient + q.quotient + q.quotient + q.residue = '10.00'::kmoney_usd)
  FROM kmoney_usd_div('10.00'::kmoney_usd, 3, 'toward_zero') q;

\echo -- the_division_identity_holds_for_every_rounding_mode
SELECT mode || '=' || (q.quotient + q.quotient + q.quotient + q.residue = '-10.00'::kmoney_usd)
  FROM unnest(ARRAY['half_even','half_away_from_zero','half_toward_zero','toward_zero','away_from_zero','floor','ceil']) AS mode,
       LATERAL kmoney_usd_div('-10.00'::kmoney_usd, 3, mode) q;

\echo -- the_residue_is_negative_under_round_up_modes
-- The identity q*n + residue = amount fixes the residue's SIGN: under a
-- round-up mode a positive amount leaves a negative residue, and a ledger
-- posting "leftover" as a nonnegative line item would mis-sign the entry.
SELECT quotient::text || ' | ' || residue::text FROM kmoney_usd_div('10.00'::kmoney_usd, 3, 'ceil');

\echo -- division_refuses_an_unknown_rounding_mode
SELECT quotient::text FROM kmoney_usd_div('10.00'::kmoney_usd, 3, 'bankers');

\echo == CASE COMPLETE: 06-div ==
