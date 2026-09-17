/* The irreducible floor: a C function that does nothing but return its argument.
 *
 * THIS IS THE CONTROL THE WHOLE PROBE RESTS ON. It has the same signature as `rs_noop` in
 * kamu-money-pg/src/lib.rs (behind `--features boundary-probe`), so both pay the same fmgr
 * dispatch and neither does any work. Whatever the pgrx one costs above this one IS the pgrx
 * per-call wrapper -- there is nothing else left in the difference.
 *
 * Compiled against the SERVER HEADERS of whichever PostgreSQL is being measured
 * (`pg_config --includedir-server`), because a function loaded by a backend has to match that
 * backend's fmgr ABI. On YugabyteDB that means the headers YugabyteDB ships, not a distribution's.
 *
 * Do not give this a body. A body is the thing being subtracted out.
 */
#include "postgres.h"
#include "fmgr.h"

PG_MODULE_MAGIC;

PG_FUNCTION_INFO_V1(c_noop);

Datum
c_noop(PG_FUNCTION_ARGS)
{
	PG_RETURN_INT64(PG_GETARG_INT64(0));
}
