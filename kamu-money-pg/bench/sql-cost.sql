-- What `kmoney_usd` costs in SQL, against `numeric(36,18)`, and WHERE the cost is. NEVER a gate.
--
-- Driven by kamu-money-pg/bench/run-bench-pg.sh (`just bench-pg`). Timed inside the server with
-- clock_timestamp rather than psql's \timing, so client round-trip and formatting are excluded.
--
-- Method:
--   1. Force every measured expression to evaluate.
--   2. Benchmark release artifacts only.
--   3. Pair each operation with floor measurements before and after it; rotate order per pass.
--   4. Disable and assert away parallel plans before reporting per-row time.
--   5. Raise on correctness failures or unusable noise; retain raw samples in the transcript.
-- No duration has a pass/fail threshold.
\set ON_ERROR_STOP 1
\pset pager off
\timing off

-- ROWS AND PASSES ARE THE CALLER'S. Stock PostgreSQL scans a local heap; YugabyteDB scans DocDB
-- over the network, so the same 500k rows cost roughly sixteen times as much wall clock there
-- and take far longer to write. The per-row figures normalise, so a smaller table on YB is still
-- comparable -- but the row count has to be RECORDED, because a ns/row column divided by the
-- wrong divisor is wrong by exactly that ratio and looks entirely plausible.
\if :{?rows}
\else
\set rows 500000
\endif
\if :{?passes}
\else
\set passes 7
\endif
\echo '=== rows:' :rows ' passes:' :passes ' ==='

CREATE EXTENSION IF NOT EXISTS kmoney_usd;

-- Set before measurement and assert below.
SET max_parallel_workers_per_gather = 0;

-- Use values inside both domains and store the same value in three representations. Read
-- `numeric+cur` for the schema-level comparison; bare numeric stays as a component-cost floor.
--
--   cur    char(3), the companion column the bare `numeric` figure pretends is free
--   canon  the canonical text form both types parse FROM, so parse is measured off a stored
--          column rather than off a string the predicate builds per row (invalid-benchmark #1)
DROP TABLE IF EXISTS t;
CREATE TABLE t AS
SELECT g AS id,
       ('USD ' || amt)::kmoney_usd       AS m,
       amt::numeric(36,18)           AS n,
       'USD'::char(3)                AS cur,
       ('USD ' || amt)               AS canon
FROM (SELECT g, (g % 100000)::text || '.' || lpad((g % 97)::text, 2, '0') AS amt
      FROM generate_series(1, :rows) g) src;
-- ANALYZE, not VACUUM ANALYZE: the table is a fresh CTAS with no dead tuples to reclaim,
-- and VACUUM is meaningless on YugabyteDB's DocDB storage. The planner needs the stats;
-- neither engine needs the vacuum.
ANALYZE t;

\echo
\echo '=== CORRECTNESS FIRST: the two columns really do hold the same value ==='
-- Raise on disagreement before timing. Compare monetary values here; render bytes are checked
-- separately.
DO $$
DECLARE disagreements bigint; render_diffs bigint; example text;
BEGIN
    -- All THREE representations, because a benchmark that compares them must first establish
    -- they hold the same value. `canon` is what the parse rows parse from, so a `canon` that
    -- disagreed with `m` would make the two parse rows measure different work.
    SELECT count(*) INTO disagreements
    FROM t
    WHERE m <> ('USD ' || n::text)::kmoney_usd
       OR m <> canon::kmoney_usd
       OR cur <> 'USD';
    IF disagreements <> 0 THEN
        RAISE EXCEPTION
            'kmoney_usd and numeric disagree on % of % rows. Nothing below this line is worth '
            'measuring: a benchmark of a wrong implementation is an argument for shipping the '
            'wrong thing.', disagreements, (SELECT count(*) FROM t);
    END IF;
    RAISE NOTICE 'correctness: 0 disagreements over % rows', (SELECT count(*) FROM t);

    -- Render comparisons require byte-identical outputs.
    SELECT count(*), min(cur || ' ' || to_char(n, 'FM99999999999999999990.00') || ' <> ' || m::text)
    INTO render_diffs, example
    FROM t
    WHERE cur || ' ' || to_char(n, 'FM99999999999999999990.00') <> m::text;
    IF render_diffs <> 0 THEN
        RAISE EXCEPTION
            'the numeric render and the kmoney_usd render disagree on % of % rows (e.g. %). Timing '
            'them against each other would compare two different outputs and call the difference '
            'a cost.', render_diffs, (SELECT count(*) FROM t), example;
    END IF;
    RAISE NOTICE 'correctness: the numeric+cur render is byte-equal to kmoney_usd''s over % rows',
        (SELECT count(*) FROM t);
END $$;

-- These SQL-language controls measure SQL call overhead, not bytea-state plumbing. Keep them
-- labelled as invalid controls so they are not mistaken for aggregate baselines.
CREATE OR REPLACE FUNCTION noop_accum(state bytea, v kmoney_usd) RETURNS bytea
  AS $$ SELECT COALESCE($1, repeat(E'\\000', 34)::bytea) $$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;
CREATE OR REPLACE FUNCTION noop_final(state bytea) RETURNS bigint
  AS $$ SELECT length($1)::bigint $$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;
DROP AGGREGATE IF EXISTS noop_sum(kmoney_usd);
CREATE AGGREGATE noop_sum(kmoney_usd) (
    SFUNC = noop_accum, STYPE = bytea, FINALFUNC = noop_final, PARALLEL = SAFE);
CREATE OR REPLACE FUNCTION cnt_accum(state bigint, v kmoney_usd) RETURNS bigint
  AS $$ SELECT COALESCE($1,0) + 1 $$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;
DROP AGGREGATE IF EXISTS cnt_sum(kmoney_usd);
CREATE AGGREGATE cnt_sum(kmoney_usd) (SFUNC = cnt_accum, STYPE = bigint, PARALLEL = SAFE);

-- One measured execution. Its own function so the sampling loop below reads as the SCHEME it is
-- rather than as four copies of clock_timestamp arithmetic.
CREATE OR REPLACE FUNCTION timed(q text) RETURNS double precision AS $f$
DECLARE t0 timestamptz;
BEGIN
    t0 := clock_timestamp();
    EXECUTE q;
    RETURN extract(epoch FROM clock_timestamp() - t0) * 1000;
END $f$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION plan_of(q text) RETURNS text AS $f$
DECLARE line text; whole text := '';
BEGIN
    FOR line IN EXECUTE 'EXPLAIN (COSTS OFF) ' || q LOOP
        whole := whole || line || E'\n';
    END LOOP;
    RETURN whole;
END $f$ LANGUAGE plpgsql;

-- `position` is retained, not just `pass`: it is the evidence that rotation happened, and it is
-- what a reader needs to check for a position effect this file has not thought of.
-- `floor_ms` is the BRACKET -- the mean of the floors immediately before and after this
-- operation -- kept per row so every delta can be recomputed from the raw table.
DROP TABLE IF EXISTS bench_samples;
CREATE TABLE bench_samples(
    op text, pass int, position int,
    ms double precision, floor_before_ms double precision, floor_after_ms double precision);

CREATE OR REPLACE FUNCTION bench_all(reps int) RETURNS void AS $f$
DECLARE
  floor_q text := 'SELECT count(*) FROM t WHERE id > 0';
  labels text[] := ARRAY[
    -- APPLES TO APPLES: `numeric+cur` is the pairing a schema actually chooses between.
    -- Bare `numeric` is kept beside it, and the gap between them is the price of the currency
    -- discipline that `kmoney_usd` gets by construction.
    'kmoney_usd:      a + b',
    'numeric+cur: a + b (currency checked)',
    'numeric:     a + b (BARE -- no currency anywhere)',
    'kmoney_usd:      a - b',
    'numeric+cur: a - b (currency checked)',
    'numeric:     a - b (BARE)',
    'kmoney_usd:      render canonical ::text',
    'numeric+cur: render canonical (to_char + concat, asserted equal)',
    'numeric:     render ::text (BARE, 18 decimals, not canonical)',
    'kmoney_usd:      parse from stored text',
    'numeric+cur: parse from stored text (split + check)',
    'native C: hashint8(id)', 'native C: abs(numeric)', 'native C: n = n',
    'pgrx:     kmoney_usd_hash(m)', 'pgrx:     kmoney_usd_sum_accum(NULL, m)',
    'sum(numeric)  [internal state, in place]', 'sum(kmoney_usd)   [bytea state, I256 math]',
    'noop_sum      [LANGUAGE sql, NO math]',   'cnt_sum       [LANGUAGE sql, by value]'];
  qs text[] := ARRAY[
    'SELECT count(*) FROM t WHERE (m + m) > ''USD -1000000000.00''::kmoney_usd',
    -- `CASE WHEN cur = cur` is not ceremony: adding two money values correctly means refusing
    -- when the currencies differ. Within a row both operands are this row's, so this is the
    -- cheapest form of the check a correct schema must perform -- and `kmoney_usd` performs it
    -- inside the operator, on every one of these adds, already counted in the row above.
    'SELECT count(*) FROM t WHERE (CASE WHEN cur = cur THEN n + n END) > -1000000000',
    'SELECT count(*) FROM t WHERE (n + n) > -1000000000',
    'SELECT count(*) FROM t WHERE (m - m) > ''USD -1000000000.00''::kmoney_usd',
    'SELECT count(*) FROM t WHERE (CASE WHEN cur = cur THEN n - n END) > -1000000000',
    'SELECT count(*) FROM t WHERE (n - n) > -1000000000',
    'SELECT count(*) FROM t WHERE length(m::text) > 0',
    -- numeric(36,18) renders ALL 18 decimals, so producing the canonical form `kmoney_usd` renders
    -- natively costs a settlement-exponent pad as well as the currency concat. The bare row below
    -- understates the render by exactly this much.
    --
    -- `to_char` emits the same settlement-width form as `kmoney_usd`; the correctness block checks it.
    --
    -- THE `.00` IS USD'S EXPONENT, HARDCODED, AND THAT FAVOURS NUMERIC. A schema that stores money
    -- in `numeric` has to look the exponent up per currency to render it; this row pays nothing
    -- for that, so it is the cheapest version of the numeric render rather than a fair one.
    -- `kmoney_usd` carries the currency in its 18 bytes and gets the exponent for free.
    'SELECT count(*) FROM t WHERE length(cur || '' '' || to_char(n, ''FM99999999999999999990.00'')) > 0',
    'SELECT count(*) FROM t WHERE length(n::text) > 0',
    -- Parse a stored column, not a string assembled inside the measured predicate.
    'SELECT count(*) FROM t WHERE canon::kmoney_usd > ''USD -1000000000.00''::kmoney_usd',
    'SELECT count(*) FROM t WHERE substr(canon, 5)::numeric(36,18) > -1000000000
                              AND substr(canon, 1, 3) = ''USD''',
    'SELECT count(*) FROM t WHERE hashint8(id) <> 0',
    'SELECT count(*) FROM t WHERE abs(n) >= 0',
    'SELECT count(*) FROM t WHERE n = n',
    'SELECT count(*) FROM t WHERE kmoney_usd_hash(m) <> 0',
    'SELECT count(*) FROM t WHERE length(kmoney_usd_sum_accum(NULL, m)) > 0',
    'SELECT sum(n) FROM t', 'SELECT sum(m) FROM t',
    'SELECT noop_sum(m) FROM t', 'SELECT cnt_sum(m) FROM t'];
  n int := array_length(qs, 1);
  p int; k int; i int;
  f_before double precision; f_after double precision; op_ms double precision;
BEGIN
  -- Warm-up, discarded: the first touch pays for caches this is not trying to measure.
  PERFORM timed(floor_q);
  FOR i IN 1..n LOOP PERFORM timed(qs[i]); END LOOP;

  FOR p IN 1..reps LOOP
    -- The pass opens on a floor, which then serves as the leading bracket of the first
    -- operation; each subsequent floor closes one bracket and opens the next. So every
    -- operation is separated from both of its floors by exactly one query, no matter where in
    -- the pass it landed.
    f_after := timed(floor_q);
    FOR k IN 0..n-1 LOOP
      -- ROTATION. Operation i occupies position k+1 on this pass and a different one on the
      -- next, so a cost that belongs to a POSITION -- cache state left by whatever ran before,
      -- a scheduler that has warmed up, drift -- cannot accumulate on one row.
      i := ((p - 1 + k) % n) + 1;
      -- Measured into variables and inserted afterwards, so the INSERT itself is never inside
      -- anything being timed.
      f_before := f_after;
      op_ms    := timed(qs[i]);
      f_after  := timed(floor_q);
      INSERT INTO bench_samples(op, pass, position, ms, floor_before_ms, floor_after_ms)
        VALUES (labels[i], p, k + 1, op_ms, f_before, f_after);
    END LOOP;
  END LOOP;
END $f$ LANGUAGE plpgsql;

\echo
\echo '=== RULE 4: the plans must be SERIAL, or ns/row is not a per-call cost ==='
DO $$
DECLARE q text; p text;
BEGIN
    FOREACH q IN ARRAY ARRAY[
        'SELECT count(*) FROM t WHERE (m + m) > ''USD -1000000000.00''::kmoney_usd',
        'SELECT count(*) FROM t WHERE kmoney_usd_hash(m) <> 0',
        'SELECT sum(m) FROM t',
        'SELECT sum(n) FROM t'] LOOP
        p := plan_of(q);
        IF p LIKE '%Gather%' THEN
            RAISE EXCEPTION
                'a parallel plan survived max_parallel_workers_per_gather = 0 for %. Wall time '
                'over the whole table would be wall-time-per-row across N workers, not a per-call '
                'cost. Plan was: %', q, p;
        END IF;
    END LOOP;
    RAISE NOTICE 'plans: serial, so ns/row below is time per row in one process';
END $$;

SELECT bench_all(:passes);

\echo
\echo '=== EVERY RAW SAMPLE. The transcript is the artefact that survives -- the container'
\echo '=== holding this table is deleted when the run ends, so a summary alone is unreproducible.'
SELECT pass, position, op,
       round(ms::numeric, 2)              AS ms,
       round(floor_before_ms::numeric, 2) AS floor_before,
       round(floor_after_ms::numeric, 2)  AS floor_after,
       round((ms - (floor_before_ms + floor_after_ms) / 2)::numeric, 2) AS delta
FROM bench_samples ORDER BY pass, position;

\echo
\echo '=== IS THIS RUN USABLE? The statistic is BRACKET DRIFT, not global spread. ==='
DO $$
DECLARE
    lo double precision; hi double precision; spread numeric;
    med_drift numeric; p90_drift numeric;
BEGIN
    SELECT min(f), max(f) INTO lo, hi
    FROM (SELECT floor_before_ms AS f FROM bench_samples
          UNION ALL SELECT floor_after_ms FROM bench_samples) x;
    spread := round((hi / lo)::numeric, 2);

    -- Each delta uses the mean of its adjacent floors, so bracket drift is its local error.
    SELECT round((percentile_cont(0.5) WITHIN GROUP (ORDER BY d))::numeric, 4),
           round((percentile_cont(0.9) WITHIN GROUP (ORDER BY d))::numeric, 4)
    INTO med_drift, p90_drift
    FROM (SELECT abs(floor_after_ms - floor_before_ms)
                 / nullif((floor_after_ms + floor_before_ms) / 2, 0) AS d
          FROM bench_samples) x;

    RAISE NOTICE 'floor: best % ms, worst % ms, global spread % (context, not the gate)',
        round(lo::numeric,2), round(hi::numeric,2), spread;
    RAISE NOTICE 'bracket drift: median %, p90 % (THIS is the gate)',
        round(med_drift * 100, 2)::text || '%', round(p90_drift * 100, 2)::text || '%';

    IF med_drift > 0.10 THEN
        RAISE EXCEPTION
            'UNUSABLE RUN: the floor moved a median of % ACROSS each measured bracket. Every '
            'delta below carries that as error, so a row whose difference is smaller than it '
            'means nothing. The summary is NOT printed -- a table of numbers gets quoted and the '
            'caveat above it does not. Re-run on a quieter host. (A data-quality refusal, not a '
            'performance threshold: no duration here has a pass/fail limit.)',
            round(med_drift * 100, 2)::text || '%';
    END IF;

    -- A backstop for the pathological case the bracket statistic cannot see: a floor that has
    -- changed regime entirely, where before/after pairs are locally consistent on both sides of
    -- a step change.
    IF spread > 3.0 THEN
        RAISE EXCEPTION
            'UNUSABLE RUN: the floor spanned %x across the run. Brackets are locally consistent '
            'but the machine did not stay the same machine.', spread;
    END IF;
END $$;

\echo '=== BRACKETED: each operation minus the mean of the floors either side of it, ==='
\echo '=== in the same pass. negative_passes > 0 means the row is BELOW the noise --  ==='
\echo '=== read no figure from it.                                                    ==='
SELECT d.op,
       round(min(d.delta)::numeric, 2) AS best_ms,
       round((percentile_cont(0.5) WITHIN GROUP (ORDER BY d.delta))::numeric, 2) AS median_ms,
       round((percentile_cont(0.5) WITHIN GROUP (ORDER BY d.delta))::numeric
             * 1000000 / :rows, 1) AS median_ns_per_row,
       count(*) FILTER (WHERE d.delta < 0) AS negative_passes,
       -- THIS ROW'S OWN NOISE FLOOR: the median distance the scan floor moved across this
       -- operation's brackets, in the same units as the column beside it. A median_ns_per_row
       -- smaller than its own noise_ns_per_row is NOT a measurement of that operation, and on
       -- YugabyteDB -- where the DocDB scan costs several times the arithmetic it carries --
       -- that is the common case rather than the exception.
       round((percentile_cont(0.5) WITHIN GROUP (ORDER BY d.drift))::numeric
             * 1000000 / :rows, 1) AS noise_ns_per_row,
       count(DISTINCT d.position) AS distinct_positions
FROM (SELECT op, pass, position,
             ms - (floor_before_ms + floor_after_ms) / 2 AS delta,
             abs(floor_after_ms - floor_before_ms)       AS drift
      FROM bench_samples) d
GROUP BY d.op ORDER BY 3;

\echo
\echo '=== the plans, so nothing above is a statement about a plan nobody looked at ==='
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
    SELECT count(*) FROM t WHERE (m + m) > 'USD -1000000000.00'::kmoney_usd;
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF) SELECT sum(m) FROM t;

\echo
\echo '=== storage, per row, apples to apples ==='
\echo '=== a numeric money column is not a money column until it has a currency beside it ==='
SELECT pg_column_size(m)                        AS kmoney_bytes,
       pg_column_size(n) + pg_column_size(cur)  AS numeric_plus_cur_bytes,
       pg_column_size(n)                        AS numeric_bare_bytes,
       pg_column_size(cur)                      AS cur_bytes
FROM t LIMIT 1;

\echo
\echo 'Read numeric+cur as the schema comparison. Bare numeric remains a component-cost floor.'
\echo 'No duration has a pass/fail threshold.'
\echo
\echo 'WHAT IS NOT IN ANY ROW: kmoney_usd REFUSES a cross-currency add, numeric+cur returns NULL for'
\echo 'it, and bare numeric returns a wrong number. That is a correctness difference, and timing'
\echo 'it would be timing three different operations.'
