-- kamu-money-pg: byte-exact ABI battery. Run IDENTICALLY on YugabyteDB 2025.2.x
-- (patched pgrx 0.19.2) and on stock PostgreSQL 15, then diff the two outputs.
-- Both are PG15, so any divergence is a pure YB-fork-ABI effect on kamu-money-pg's
-- custom-type code path -- the part the exp-pgrx-yb uuid probe could not cover.
--
--   psql -X -v ON_ERROR_STOP=0 -f abi_battery.sql > out.txt 2>&1
--
-- ON_ERROR_STOP=0: several probes below EXPECT an error, and the error TEXT is
-- part of what must match A/B. Deterministic output only (no timestamps/oids).
--
-- SCOPE: the per-currency types are amount SCALARS for OLTP wallet/ledger schemas --
-- native storage + arithmetic + equality. A column type, not a store: this extension
-- implements no account, transaction or balance. Amount columns are assumed not to be
-- ordered/ranged/indexed by value (that is OLAP, and a custom type's default-opclass
-- ordering was the sole YugabyteDB edge), so there is no btree or hash opclass, no
-- ORDER BY amount, and no value index anywhere in this battery.

\pset pager off
\pset footer off
\set ECHO none
CREATE EXTENSION IF NOT EXISTS kmoney;

-- Normalize infrastructure chatter so the A/B diff compares the extension's behavior, not
-- the server's: YugabyteDB emits a WARNING about ROWS_PER_TRANSACTION batching when COPY
-- targets a temp table (case 2b), which stock PG15 has no notion of. Neither is an
-- extension effect. ERRORs (which the refusal probes assert) are level ERROR and still print.
SET client_min_messages = error;

\echo == 1. text round-trip (custom FromDatum/IntoDatum over 16 bytes) ==
SELECT '10.50'::kmoney_usd::text AS usd,
       'USD 10.50'::kmoney_usd::text AS usd_tagged,
       '16000.01'::kmoney_idr::text AS idr,
       '10.5'::kmoney_jpy::text AS jpy,
       '10.500'::kmoney_kwd::text AS kwd,
       ('-0.000000000000000001'::kmoney_usd)::text AS tiny_neg,
       ('999999999999999999.999999999999999999'::kmoney_usd)::text AS domain_top;
SELECT typname, typlen, typbyval, typalign, typstorage
  FROM pg_type WHERE typname IN ('kmoney_usd', 'kmoney_mixed') ORDER BY typname;

\echo == 2. binary send() widths + bytea (raw SEND path) ==
SELECT length(kmoney_usd_send('10.50'::kmoney_usd)) AS pinned_send_len,
       length(kmoney_mixed_send('USD 10.50'::kmoney_mixed)) AS mixed_send_len,
       encode(kmoney_usd_send('1.00'::kmoney_usd), 'hex') AS usd_one_hex;

\echo == 2b. COPY (FORMAT BINARY) round trip on BOTH families: send out, recv back in ==
-- COPY is the in-database path that invokes the recv functions; their argument is `internal`
-- and cannot be provided by a SQL literal. Server-side file; single session, fixed names.
-- The pinned recv is ONE shared symbol behind 178 declarations, so one type proves the path.
CREATE TEMP TABLE wire_src (amount kmoney_usd);
INSERT INTO wire_src VALUES ('-16000.50'),
                            ('0.000000000000000001'),
                            ('999999999999999999.999999999999999999');
COPY wire_src TO '/tmp/kmoney_abi_wire.bin' (FORMAT BINARY);
CREATE TEMP TABLE wire_dst (LIKE wire_src);
COPY wire_dst FROM '/tmp/kmoney_abi_wire.bin' (FORMAT BINARY);
SELECT (SELECT count(*) FROM wire_dst) AS rows_recv,
       (SELECT array_agg(amount::text ORDER BY amount::text) FROM wire_src)
         = (SELECT array_agg(amount::text ORDER BY amount::text) FROM wire_dst)
         AS roundtrip_exact;
CREATE TEMP TABLE wire_src_mixed (amount kmoney_mixed);
INSERT INTO wire_src_mixed VALUES ('IDR -16000.50'), ('USD 0.000000000000000001');
COPY wire_src_mixed TO '/tmp/kmoney_abi_wire_mixed.bin' (FORMAT BINARY);
CREATE TEMP TABLE wire_dst_mixed (LIKE wire_src_mixed);
COPY wire_dst_mixed FROM '/tmp/kmoney_abi_wire_mixed.bin' (FORMAT BINARY);
SELECT (SELECT array_agg(amount::text ORDER BY amount::text) FROM wire_src_mixed)
         = (SELECT array_agg(amount::text ORDER BY amount::text) FROM wire_dst_mixed)
         AS mixed_roundtrip_exact;

\echo == 3. arithmetic: + - within a type; cross-currency has NO OPERATOR ==
SELECT ('10.50'::kmoney_usd + '0.25'::kmoney_usd)::text AS sum,
       ('10.50'::kmoney_usd - '0.25'::kmoney_usd)::text AS diff;
\echo -- cross-currency + must fail at PARSE time, 42883 (message must match A/B):
SELECT ('1.00'::kmoney_usd + '1.00'::kmoney_idr)::text AS must_error;

\echo == 4. sum() aggregate (bytea transition state) incl the domain-edge transient ==
-- Partial sums leave the domain while the total does not: the I256 transition
-- state crosses the fmgr boundary on every row, which nothing else here does.
SELECT sum(a)::text AS agg_across_a_domain_edge
  FROM (VALUES ('999999999999999999.999999999999999999'::kmoney_usd),
               ('999999999999999999.999999999999999999'::kmoney_usd),
               ('-999999999999999999.999999999999999999'::kmoney_usd)) t(a);
SELECT sum(a)::text IS NULL AS empty_is_null
  FROM (SELECT '1.00'::kmoney_usd WHERE false) t(a);

\echo == 5. allocate including the zero-weight guard and the remainder scheme ==
SELECT string_agg(part::text, ' | ') AS even
  FROM unnest(kmoney_usd_allocate('10.00', ARRAY[1,1,1])) part;
SELECT string_agg(part::text, ' | ') AS zero_weight
  FROM unnest(kmoney_usd_allocate('0.000000000000000001', ARRAY[0,1,1])) part;
-- Leftover units land on the FIRST positive-weight shares (not largest remainder).
SELECT string_agg(part::text, ' | ') AS first_positive
  FROM unnest(kmoney_usd_allocate('0.000000000000000008', ARRAY[1,1,3])) part;
SELECT sum(part)::text AS conserves
  FROM unnest(kmoney_idr_allocate('16000.01', ARRAY[7,2,1])) part;

\echo == 6. comparison operators as PREDICATES (within a type; cross-type cannot parse) ==
SELECT ('1.00'::kmoney_usd <  '2.00'::kmoney_usd) AS lt,
       ('2.00'::kmoney_usd >= '2.00'::kmoney_usd) AS ge;
CREATE TEMP TABLE pred (amount kmoney_usd);
INSERT INTO pred VALUES ('1.00'),('2.00'),('1.00');
SELECT count(*) AS usd_ones FROM pred WHERE amount = '1.00'::kmoney_usd;
\echo -- cross-currency ORDERING must fail at PARSE time, 42883 (message must match A/B):
SELECT ('1.00'::kmoney_idr > '1.00'::kmoney_usd) AS must_error;

\echo == 7. PINNED hash values (the sharpest custom-type ABI signal) ==
-- These i32 come from kamu_money_core::stable_hash golden vectors. If the 16-byte
-- payload is read at a wrong offset on YB, these diverge -- silently-wrong money
-- made visible. The hash is a plain function (no hash opclass/index).
SELECT kmoney_usd_hash('0.00'::kmoney_usd)  AS h_usd_0,
       kmoney_usd_hash('1.00'::kmoney_usd)  AS h_usd_1,
       kmoney_idr_hash('1.00'::kmoney_idr)  AS h_idr_1,
       kmoney_usd_hash('-1.00'::kmoney_usd) AS h_usd_neg1;
SELECT kmoney_usd_hash('1.00'::kmoney_usd) = kmoney_mixed_hash('USD 1.00'::kmoney_mixed) AS same_logical_same_hash;

\echo == 8. the mixed type: total equality, no arithmetic, no sum ==
SELECT ('USD 1.00'::kmoney_mixed = 'IDR 1.00'::kmoney_mixed) AS mixed_cross_eq_false;
CREATE TEMP TABLE pred_mixed (amount kmoney_mixed);
INSERT INTO pred_mixed VALUES ('USD 1.00'),('USD 2.00'),('IDR 1.00'),('USD 1.00');
SELECT count(*) AS mixed_usd_ones FROM pred_mixed WHERE amount = 'USD 1.00'::kmoney_mixed;
\echo -- sum(kmoney_mixed) must remain unavailable because mixed rows have no single currency:
SELECT sum(a) FROM (VALUES ('USD 1.00'::kmoney_mixed)) t(a);

\echo == 9. domain + precision + wrong-tag refusals (parse path) ==
-- Bare literals reach the pinned domain branch directly; the tagged probe is the
-- wire-correctness heart: a well-formed value of the WRONG currency is refused.
SELECT '1000000000000000000.00'::kmoney_usd;              -- one past the domain: ERROR
SELECT '0.0000000000000000005'::kmoney_usd;               -- 19dp: ERROR, never rounded
SELECT 'IDR 1.00'::kmoney_usd;                            -- wrong tag: ERROR

\echo == BATTERY COMPLETE ==
