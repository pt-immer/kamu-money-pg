-- 09-wire: `send`/`recv` -- the only path that takes attacker-shaped bytes straight into an
-- unsafe FFI function.
--
-- Ports: the_binary_wire_round_trips_and_is_not_more_trusted_than_text,
-- the_pinned_binary_wire_round_trips, pinned_recv_refuses_an_out_of_domain_binary_payload,
-- recv_refuses_an_out_of_domain_binary_payload, recv_refuses_a_truncated_binary_payload,
-- recv_refuses_a_binary_payload_with_trailing_bytes,
-- recv_refuses_a_binary_payload_whose_currency_is_unknown.
--
-- HOW THE CRAFTED PAYLOADS GET HERE. `kmoney_mixed_recv` cannot be called from SQL: its argument is
-- `internal`, which has no literal. The only in-database route to it is COPY (FORMAT BINARY),
-- which needs a file. The Rust tests build those files inside the backend with std::fs; this
-- suite cannot, so sql/09-wire.setup.sh writes them on the SERVER before the case runs --
-- byte-for-byte from constants, with no database involved.
--
-- That is a STRONGER provenance than the Rust version, not a weaker one: the good payload is
-- pinned in the repo rather than produced by the very code under test. And the first probe below
-- asserts that a real `kmoney_mixed_send` still emits exactly those bytes, so the crafted files
-- cannot quietly drift away from what the type actually writes.
\pset pager off
\pset footer off
\pset format unaligned
\pset tuples_only on
\pset null '<NULL>'
\set VERBOSITY terse
\set wire_file :kmoney_suite_dir '/wire.bin'
\set pin_wire_file :kmoney_suite_dir '/pin_wire.bin'
\set bad_domain_file :kmoney_suite_dir '/kmoney_suite_bad_domain.bin'
\set bad_pin_domain_file :kmoney_suite_dir '/kmoney_suite_bad_pin_domain.bin'
\set bad_short_file :kmoney_suite_dir '/kmoney_suite_bad_short.bin'
\set bad_long_file :kmoney_suite_dir '/kmoney_suite_bad_long.bin'
\set bad_nocur_file :kmoney_suite_dir '/kmoney_suite_bad_nocur.bin'
SET client_min_messages = error;
CREATE EXTENSION IF NOT EXISTS kmoney;

\echo -- the_binary_wire_round_trips_and_is_not_more_trusted_than_text
-- BOTH families advertise both directions. Without RECEIVE a binary COPY dump
-- would be write-only, a `binary = true` logical-replication subscription could
-- never complete its initial sync, and PostgreSQL offers no `ALTER TYPE ...
-- RECEIVE` to add it after the freeze.
SELECT 'types=' || count(*) || ' all_send=' || bool_and(typsend <> 0)
    || ' all_recv=' || bool_and(typreceive <> 0)
  FROM pg_type WHERE typname IN ('kmoney_mixed', 'kmoney_usd');
CREATE TEMP TABLE bin_io (amount kmoney_mixed);
INSERT INTO bin_io VALUES ('IDR -16000.50'), ('USD 0.000000000000000001');
SELECT 'send_widths=' || octet_length(kmoney_usd_send('1.00'::kmoney_usd))
    || '/' || octet_length(kmoney_mixed_send('USD 1.00'::kmoney_mixed));
-- The exact 18 payload bytes for USD 1.00: 16 little-endian units (10^18) then the ISO numeric
-- code 840, little-endian. sql/09-wire.setup.sh builds every crafted file from these same bytes.
SELECT 'usd_one_hex=' || encode(kmoney_mixed_send('USD 1.00'::kmoney_mixed), 'hex');
-- COPY out and back in is the real client path: send on the way out, recv on the way back.
COPY bin_io TO :'wire_file' (FORMAT BINARY);
CREATE TEMP TABLE bin_copy (LIKE bin_io);
COPY bin_copy FROM :'wire_file' (FORMAT BINARY);
-- Compare the ORDERED text projections, never a JOIN USING(amount): a mangled row fails to pair
-- and drops out of an inner join, leaving the mismatch count at zero -- a tautology.
SELECT 'roundtrip_exact=' || ((SELECT array_agg(amount::text ORDER BY amount::text) FROM bin_io)
                            = (SELECT array_agg(amount::text ORDER BY amount::text) FROM bin_copy))
    || ' rows=' || (SELECT count(*) FROM bin_copy);

\echo -- the_pinned_binary_wire_round_trips
-- The pinned recv is ONE shared symbol behind 178 per-type declarations: the
-- payload is currency-less, so the RETURNS clause is what types the result.
CREATE TEMP TABLE pin_io (amount kmoney_usd);
INSERT INTO pin_io VALUES ('-16000.50'), ('0.000000000000000001');
COPY pin_io TO :'pin_wire_file' (FORMAT BINARY);
CREATE TEMP TABLE pin_copy (LIKE pin_io);
COPY pin_copy FROM :'pin_wire_file' (FORMAT BINARY);
SELECT 'pinned_roundtrip_exact=' || ((SELECT array_agg(amount::text ORDER BY amount::text) FROM pin_io)
                                   = (SELECT array_agg(amount::text ORDER BY amount::text) FROM pin_copy))
    || ' rows=' || (SELECT count(*) FROM pin_copy);

\echo -- pinned_recv_refuses_an_out_of_domain_binary_payload
-- The 16-byte crafted probe: one past the domain top, no currency bytes to be
-- wrong. The refusal must name the per-type SQL function the shared symbol was
-- reached through.
CREATE TEMP TABLE pin_recv_domain (amount kmoney_usd);
COPY pin_recv_domain FROM :'bad_pin_domain_file' (FORMAT BINARY);

\echo -- recv_refuses_an_out_of_domain_binary_payload
-- Binary is NOT more trusted than text. Only the 16-byte units field is overwritten (with
-- 10^36, one past the domain top); the currency code stays valid, so it is the DOMAIN check that
-- fires, with a kamu_money_core-owned and therefore version-stable message.
CREATE TEMP TABLE recv_domain (amount kmoney_mixed);
COPY recv_domain FROM :'bad_domain_file' (FORMAT BINARY);

\echo -- recv_refuses_a_truncated_binary_payload
-- The memory-safety half of the recv contract: the payload is a fixed [u8; 18], and if
-- pq_copymsgbytes did not raise when fewer than 18 bytes remain, the tail would stay
-- UNINITIALISED and be reinterpreted as units -- money read out of whatever was in that memory.
-- The field length is cut to 10 AND the payload truncated to match, so the file stays
-- self-consistent and it is recv, not COPY's own framing check, that refuses.
CREATE TEMP TABLE recv_short (amount kmoney_mixed);
COPY recv_short FROM :'bad_short_file' (FORMAT BINARY);

\echo -- recv_refuses_a_binary_payload_with_trailing_bytes
-- "We read what we expected and moved on" is how a re-framed or version-skewed payload gets
-- silently accepted as a different amount. The expected message is pq_getmsgend's, NOT COPY's:
-- delete the pq_getmsgend call and PostgreSQL's own post-check still errors, but with "improper
-- binary format in file". So this goes red on exactly the guard it pins.
CREATE TEMP TABLE recv_long (amount kmoney_mixed);
COPY recv_long FROM :'bad_long_file' (FORMAT BINARY);

\echo -- recv_refuses_a_binary_payload_whose_currency_is_unknown
-- The currency half. Units left valid; only the 2-byte ISO code is overwritten with 0, which is
-- not an assigned ISO 4217 numeric code.
CREATE TEMP TABLE recv_nocur (amount kmoney_mixed);
COPY recv_nocur FROM :'bad_nocur_file' (FORMAT BINARY);

\echo == CASE COMPLETE: 09-wire ==
