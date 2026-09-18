-- Measure pgrx call-boundary cost. Never a gate.
--
-- Driven by kamu-money-pg/bench/boundary/in-container.sh (`just bench-boundary`).
--
-- C and `#[pg_extern]` controls share the `bigint -> bigint` identity signature
-- and fmgr dispatch; their difference isolates the pgrx wrapper. `generate_series`
-- keeps DocDB out of the path while preserving YSQL's memory-context behavior.
--
-- Sampling brackets each operation with floors and rotates order between passes
-- to reduce drift bias. Parallel workers are disabled because wall time per row
-- is meaningful only when one process executes the rows.
\set ON_ERROR_STOP 1
\pset pager off
\timing off

SET max_parallel_workers_per_gather = 0;

CREATE EXTENSION IF NOT EXISTS kmoney_usd;

-- The C control, compiled against THIS server's headers -- by in-container.sh on stock
-- PostgreSQL, by the `boundary-build` Dockerfile stage on YugabyteDB. The path differs between
-- them, so the caller names it rather than this file guessing: `-v c_noop_so=<path>`.
-- A SENTINEL rather than `\quit`, because `\quit` ends the script with status 0 and the runner
-- would read that as a successful measurement that printed nothing. The bad path makes
-- CREATE FUNCTION fail, and `ON_ERROR_STOP` turns that into a non-zero exit.
\if :{?c_noop_so}
\else
\echo 'probe.sql: c_noop_so is not set. Pass the path to the compiled control, e.g.'
\echo '  psql -v c_noop_so=/tmp/c_noop.so -f probe.sql'
\echo 'There is no default, because a default would silently load whichever c_noop.so happened'
\echo 'to be lying around -- possibly one compiled against a DIFFERENT server''s headers, which'
\echo 'is the one thing this measurement cannot survive.'
\set c_noop_so 'c_noop_so-WAS-NOT-SET-see-the-message-above'
\endif
CREATE FUNCTION c_noop(bigint) RETURNS bigint
    AS :'c_noop_so', 'c_noop' LANGUAGE C STRICT IMMUTABLE PARALLEL SAFE;

-- Both pgrx probes must exist, or the run is measuring something other than what it says.
-- `--features boundary-probe` is one flag away from being forgotten, and a probe that silently
-- measured four rows instead of six would still print a plausible table.
DO $$
BEGIN
    PERFORM 1 FROM pg_proc WHERE proname = 'rs_noop';
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'rs_noop is not installed. The extension was built without --features '
            'boundary-probe, so there is no pgrx side to compare against. Refusing to print a '
            'boundary table with no boundary in it.';
    END IF;
    PERFORM 1 FROM pg_proc WHERE proname = 'rs_noop_kmoney';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'rs_noop_kmoney is not installed (see above).';
    END IF;
END $$;

CREATE TABLE probe_samples(
    op text, pass int, position int,
    ms double precision, floor_before_ms double precision, floor_after_ms double precision);

CREATE OR REPLACE FUNCTION timed(q text) RETURNS double precision AS $f$
DECLARE t0 timestamptz;
BEGIN
    t0 := clock_timestamp();
    EXECUTE q;
    RETURN extract(epoch FROM clock_timestamp() - t0) * 1000;
END $f$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION probe(reps int, n bigint) RETURNS void AS $f$
DECLARE
  floor_q text := format('SELECT count(*) FROM generate_series(1,%s) g WHERE g > 0', n);
  -- ONLY THE `bigint` PAIR, AND THE MISSING ROWS ARE THE POINT.
  --
  -- Constant `kmoney_usd` arguments would let PostgreSQL fold these immutable calls at plan time.
  --
  -- The two forms are a vice. An argument that varies with `g` has to be BUILT from `g`, and
  -- building an 18-byte currency-tagged value costs hundreds of nanoseconds -- swamping the few
  -- this probe exists to resolve. An argument that does not vary gets folded away. There is no
  -- third option without a per-row source of `kmoney_usd` values, which means a table, which puts
  -- DocDB back in the path on YugabyteDB and reintroduces the variance the no-table design
  -- exists to escape.
  --
  -- So the typed rows are NOT measured here. `sql-cost.sql` prices `kmoney_usd_hash` over a real
  -- table, where a scan is the point rather than the obstacle; this file answers the narrower
  -- question the "why pgrx" argument actually rests on -- what does CROSSING cost -- and
  -- `bigint` answers it exactly, because both sides have identical signatures.
  labels text[] := ARRAY[
    'null C:    c_noop(bigint)',
    'null pgrx: rs_noop(bigint)'];
  qs text[] := ARRAY[
    -- `g::bigint`, so the argument varies per row and cannot be folded, while the cast itself is
    -- on BOTH sides of the comparison and cancels in the difference.
    format('SELECT count(*) FROM generate_series(1,%s) g WHERE c_noop(g::bigint) <> -1', n),
    format('SELECT count(*) FROM generate_series(1,%s) g WHERE rs_noop(g::bigint) <> -1', n)];
  m int := array_length(qs, 1);
  p int; k int; i int;
  f_before double precision; f_after double precision; op_ms double precision;
BEGIN
  PERFORM timed(floor_q);
  FOR i IN 1..m LOOP PERFORM timed(qs[i]); END LOOP;

  FOR p IN 1..reps LOOP
    f_after := timed(floor_q);
    FOR k IN 0..m-1 LOOP
      i := ((p - 1 + k) % m) + 1;
      f_before := f_after;
      op_ms    := timed(qs[i]);
      f_after  := timed(floor_q);
      INSERT INTO probe_samples(op, pass, position, ms, floor_before_ms, floor_after_ms)
        VALUES (labels[i], p, k + 1, op_ms, f_before, f_after);
    END LOOP;
  END LOOP;
END $f$ LANGUAGE plpgsql;

\echo
\echo '=== the plans must be SERIAL, or ns/call is not a per-call cost ==='
DO $$
DECLARE line text;
BEGIN
    FOR line IN EXECUTE
        'EXPLAIN (COSTS OFF) SELECT count(*) FROM generate_series(1,1000) g WHERE rs_noop(g::bigint) <> -1'
    LOOP
        IF line LIKE '%Gather%' THEN
            RAISE EXCEPTION 'a parallel plan survived max_parallel_workers_per_gather = 0: %', line;
        END IF;
    END LOOP;
    RAISE NOTICE 'plans: serial';
END $$;

SELECT probe(9, 1000000);

\echo
\echo '=== EVERY RAW SAMPLE. The container is deleted when the run ends, so the transcript'
\echo '=== is the only artefact that survives.'
SELECT pass, position, op,
       round(ms::numeric, 2)              AS ms,
       round(floor_before_ms::numeric, 2) AS floor_before,
       round(floor_after_ms::numeric, 2)  AS floor_after,
       round((ms - (floor_before_ms + floor_after_ms) / 2)::numeric, 2) AS delta
FROM probe_samples ORDER BY pass, position;

\echo
\echo '=== IS THIS RUN USABLE? A few ns cannot be read off an unstable floor. ==='
DO $$
DECLARE lo double precision; hi double precision; spread numeric;
BEGIN
    SELECT min(f), max(f) INTO lo, hi
    FROM (SELECT floor_before_ms AS f FROM probe_samples
          UNION ALL SELECT floor_after_ms FROM probe_samples) x;
    spread := round((hi / lo)::numeric, 2);
    RAISE NOTICE 'floor: best % ms, worst % ms, spread %',
        round(lo::numeric,2), round(hi::numeric,2), spread;
    -- TIGHTER THAN sql-cost.sql's 1.5. That fixture resolves tens of ns between operations that
    -- differ by hundreds; this one is trying to resolve single-digit ns, so it needs a quieter
    -- host and should say so rather than print a table nobody can trust.
    IF spread > 1.25 THEN
        RAISE EXCEPTION
            'UNUSABLE RUN: the floor varied by %x. This probe resolves single-digit '
            'nanoseconds and cannot do that against a floor moving by more than a quarter. The '
            'summary is NOT printed -- re-run on a quiet host. (A data-quality refusal, not a '
            'performance threshold.)', spread;
    END IF;
END $$;

\echo
\echo '=== ELIMINATION CHECK: a function that measures at or below the floor did not run. ==='
-- An immutable constant call can fold at plan time, and an unused projection can disappear.
-- A delta at or below the floor therefore invalidates the row.
DO $$
DECLARE bad text;
BEGIN
    SELECT string_agg(format('%s (median %s ms, %s of %s passes below the floor)',
                             op, round(med::numeric, 2), neg, tot), '; ')
    INTO bad
    FROM (SELECT op,
                 percentile_cont(0.5) WITHIN GROUP (ORDER BY delta) AS med,
                 count(*) FILTER (WHERE delta < 0) AS neg,
                 count(*) AS tot
          FROM (SELECT op, ms - (floor_before_ms + floor_after_ms) / 2 AS delta
                FROM probe_samples) d
          GROUP BY op) g
    WHERE med <= 0;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION
            'ELIMINATED, NOT FAST: %. A median at or below the floor means the call did not '
            'happen per row -- constant-folded because the function is IMMUTABLE and its '
            'argument constant, or projected away because nothing consumed the result. No '
            'figure can be read from those rows, and a table printed beneath this line would be '
            'quoted anyway.', bad;
    END IF;
    RAISE NOTICE 'elimination check: every measured row is above the floor';
END $$;

\echo
\echo '=== THE BOUNDARY. rs_noop minus c_noop IS the pgrx per-call wrapper: same signature, ==='
\echo '=== same fmgr dispatch, neither does any work.                                       ==='
SELECT d.op,
       round((percentile_cont(0.5) WITHIN GROUP (ORDER BY d.delta))::numeric, 2) AS median_ms,
       round((percentile_cont(0.5) WITHIN GROUP (ORDER BY d.delta))::numeric
             * 1000000 / 1000000, 2) AS median_ns_per_call,
       count(*) FILTER (WHERE d.delta < 0) AS negative_passes,
       count(DISTINCT d.position) AS distinct_positions
FROM (SELECT op, pass, position,
             ms - (floor_before_ms + floor_after_ms) / 2 AS delta
      FROM probe_samples) d
GROUP BY d.op ORDER BY 3;

\echo
\echo 'negative_passes > 0 means the row is BELOW this run''s noise -- read no figure from it,'
\echo 'and in particular do not read "zero cost" from it. It means the ruler is too coarse.'
