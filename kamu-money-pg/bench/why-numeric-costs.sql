-- WHY does `numeric` cost so much more than `kmoney_usd` on YugabyteDB? NEVER a gate.
--
-- Run through kamu-money-pg/bench/run-bench-sql-yb.sh (`just bench-why-yb`).
--
-- Distinguish two explanations for numeric cost. `bytea` is variable-length like `numeric` and
-- opaque like `kmoney_usd`, so the predictions differ:
--
--     varlena-vs-fixed  =>  bytea ~ numeric  >>  kmoney_usd
--     numeric-specific  =>  bytea ~ kmoney_usd   <<  numeric
--
-- The fixture establishes ordering and noise from each retained run. DocDB decimal translation
-- remains an inference; this file measures numeric-specific cost, not DocDB internals.
\set ON_ERROR_STOP 1
\pset pager off
\timing off

\if :{?rows}
\else
\set rows 100000
\endif
\if :{?passes}
\else
\set passes 9
\endif
\echo '=== rows:' :rows ' passes:' :passes ' ==='

SET max_parallel_workers_per_gather = 0;
CREATE EXTENSION IF NOT EXISTS kmoney_usd;

-- The SAME value in five representations. `b` is `kmoney_usd_send` output, so it is the identical
-- 18 bytes as `m` -- the only difference between those two columns is that one is declared
-- variable-length and the other fixed.
-- IDEMPOTENT, like sql-cost.sql. A fixture that only runs once against a given database fails
-- with `already exists` on the second attempt, which reads as a broken fixture rather than as a
-- dirty database -- and the runner reuses a container when a rerun is what is wanted.
DROP TABLE IF EXISTS w;
CREATE TABLE w AS
SELECT g AS id,
       ('USD ' || amt)::kmoney_usd   AS m,
       amt::numeric(36,18)       AS n,
       kmoney_usd_send(('USD ' || amt)::kmoney_usd) AS b,
       amt                       AS t
FROM (SELECT g, (g % 100000)::text || '.' || lpad((g % 97)::text, 2, '0') AS amt
      FROM generate_series(1, :rows) g) src;
ANALYZE w;

\echo
\echo '=== per-row storage of the five columns ==='
SELECT pg_column_size(id) AS bigint_b, pg_column_size(m) AS kmoney_b,
       pg_column_size(b)  AS bytea_b,  pg_column_size(t) AS text_b,
       pg_column_size(n)  AS numeric_b
FROM w LIMIT 1;

CREATE OR REPLACE FUNCTION timed(q text) RETURNS double precision AS $f$
DECLARE t0 timestamptz;
BEGIN t0 := clock_timestamp(); EXECUTE q;
      RETURN extract(epoch FROM clock_timestamp() - t0) * 1000; END $f$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION plan_of(q text) RETURNS text AS $f$
DECLARE line text; whole text := '';
BEGIN
    FOR line IN EXECUTE 'EXPLAIN (COSTS OFF) ' || q LOOP whole := whole || line || E'\n'; END LOOP;
    RETURN whole;
END $f$ LANGUAGE plpgsql;

-- Retain position so rotation and position effects remain auditable.
DROP TABLE IF EXISTS s;
CREATE TABLE s(op text, pass int, position int,
               ms double precision, fb double precision, fa double precision);

\echo
\echo '=== CORRECTNESS FIRST: all five predicates must match the SAME rows ==='
-- Five `x = x` scans are comparable only if every predicate returns every row.
DO $$
DECLARE q text; got bigint; want bigint;
BEGIN
    SELECT count(*) INTO want FROM w;
    FOREACH q IN ARRAY ARRAY[
        'SELECT count(*) FROM w WHERE id = id',
        'SELECT count(*) FROM w WHERE m = m',
        'SELECT count(*) FROM w WHERE b = b',
        'SELECT count(*) FROM w WHERE t = t',
        'SELECT count(*) FROM w WHERE n = n'] LOOP
        EXECUTE q INTO got;
        IF got <> want THEN
            RAISE EXCEPTION
                '% returned % of % rows. The five columns hold the same value in five '
                'representations, so a predicate that matches fewer is doing different work and '
                'its timing is not comparable with the others.', q, got, want;
        END IF;
    END LOOP;
    RAISE NOTICE 'correctness: all five predicates match all % rows', want;
END $$;

\echo
\echo '=== THE PLANS MUST BE SERIAL, or ns/row is not a per-row cost ==='
-- `SET max_parallel_workers_per_gather = 0` above is a REQUEST. Asserting the plans is what makes
-- it a fact: under a Gather, wall time over the whole table is wall-time-per-row across N workers,
-- and dividing by :rows would understate every row by the worker count.
DO $$
DECLARE q text; p text;
BEGIN
    FOREACH q IN ARRAY ARRAY[
        'SELECT count(*) FROM w WHERE id = id',
        'SELECT count(*) FROM w WHERE m = m',
        'SELECT count(*) FROM w WHERE b = b',
        'SELECT count(*) FROM w WHERE t = t',
        'SELECT count(*) FROM w WHERE n = n',
        'SELECT count(*) FROM w WHERE id > 0'] LOOP
        p := plan_of(q);
        IF p LIKE '%Gather%' THEN
            RAISE EXCEPTION
                'a parallel plan survived max_parallel_workers_per_gather = 0 for %. Plan was: %',
                q, p;
        END IF;
    END LOOP;
    RAISE NOTICE 'plans: serial, so ns/row below is time per row in one process';
END $$;

-- `x = x` for every column: the same operation SHAPE on five different types, so what varies is
-- the type rather than the work. Bracketed and rotated exactly as sql-cost.sql is.
CREATE OR REPLACE FUNCTION run(reps int) RETURNS void AS $f$
DECLARE
  fq text := 'SELECT count(*) FROM w WHERE id > 0';
  labels text[] := ARRAY[
    'bigint  i = i (fixed 8B)',
    'kmoney_usd  m = m (fixed 18B, opaque to YB)',
    'bytea   b = b (VARLENA, opaque to YB)',
    'text    t = t (VARLENA, YB-native)',
    'numeric n = n (VARLENA, YB-native Decimal)'];
  qs text[] := ARRAY[
    'SELECT count(*) FROM w WHERE id = id',
    'SELECT count(*) FROM w WHERE m = m',
    'SELECT count(*) FROM w WHERE b = b',
    'SELECT count(*) FROM w WHERE t = t',
    'SELECT count(*) FROM w WHERE n = n'];
  n int := array_length(qs, 1);
  k int; p int; i int;
  fb double precision; fa double precision; om double precision;
BEGIN
  PERFORM timed(fq);
  FOR i IN 1..n LOOP PERFORM timed(qs[i]); END LOOP;
  FOR p IN 1..reps LOOP
    fa := timed(fq);
    FOR k IN 0..n-1 LOOP
      i  := ((p - 1 + k) % n) + 1;
      fb := fa;
      om := timed(qs[i]);
      fa := timed(fq);
      INSERT INTO s(op, pass, position, ms, fb, fa) VALUES (labels[i], p, k + 1, om, fb, fa);
    END LOOP;
  END LOOP;
END $f$ LANGUAGE plpgsql;

SELECT run(:passes);

\echo
\echo '=== EVERY RAW SAMPLE, in pass/position order. The transcript is the artefact that'
\echo '=== survives: the container holding this table is deleted when the run ends, so a'
\echo '=== median table alone cannot be recomputed or checked by anybody afterwards.'
-- The summary below is derived from these retained rows.
SELECT pass, position, op,
       round(ms::numeric, 2) AS ms,
       round(fb::numeric, 2) AS floor_before,
       round(fa::numeric, 2) AS floor_after,
       round((ms - (fb + fa) / 2)::numeric, 2) AS delta
FROM s ORDER BY pass, position;

\echo
\echo '=== usability: bracket drift is the gate, as in sql-cost.sql ==='
DO $$
DECLARE d numeric;
BEGIN
    SELECT round((percentile_cont(0.5) WITHIN GROUP (ORDER BY abs(fa-fb)/nullif((fa+fb)/2,0)))::numeric,4)
    INTO d FROM s;
    RAISE NOTICE 'bracket drift: median %', (d*100)::text || '%';
    IF d > 0.10 THEN
        RAISE EXCEPTION 'UNUSABLE RUN: floor moved a median of % across each bracket.', (d*100)::text || '%';
    END IF;
END $$;

\echo
\echo '=== THE DISCRIMINATOR: bytea and numeric are BOTH varlenas. ==='
\echo '=== If they land together, variable length is the cost.      ==='
\echo '=== If bytea lands with kmoney_usd, the cost is numeric-specific.==='
SELECT op,
       round((percentile_cont(0.5) WITHIN GROUP (ORDER BY ms-(fb+fa)/2))::numeric*1000000/:rows,1) AS ns_per_row,
       round((percentile_cont(0.5) WITHIN GROUP (ORDER BY abs(fa-fb)))::numeric*1000000/:rows,1)   AS noise_ns_per_row,
       count(*) FILTER (WHERE ms-(fb+fa)/2 < 0) AS negative_passes
FROM s GROUP BY op ORDER BY 2;
