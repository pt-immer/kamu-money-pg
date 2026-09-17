# kamu-money-pg — extension lane contract

`extensions/money-pg` is an excluded Cargo workspace containing the `kmoney`
pgrx extension and its database validation harness. It implements the
PostgreSQL side of
[`kamu-money-core`'s PostgreSQL boundary](../../crates/money-core/DESIGN.md#the-postgresql-boundary).

Current support:

- PostgreSQL 15, 16, 17, and 18;
- YugabyteDB at the digest recorded in
  [`YB-PINNED.txt`](kamu-money-pg/yb/YB-PINNED.txt);
- Edition 2024 and Rust 1.96;
- pgrx 0.19.2 through the `pt-immer/pgrx-yugabytedb` fork.

## Workspace boundary

```text
extensions/money-pg/
├── Cargo.toml             nested workspace, patch, profiles, MSRV
├── Cargo.lock             lane-only dependency graph
├── deny.toml              lane-only advisory and license policy
├── hygiene/               pgrx-free structural guards and payload tests
└── kamu-money-pg/         pgrx cdylib, SQL cases, Docker and YB harness
```

The lane is excluded from the repository root because Cargo honors
`[patch.crates-io]` and profiles only at a workspace root. Adding the pgrx fork
to the public workspace would also put git dependencies and PostgreSQL backend
features into the lockfile and audit surface of nine unrelated crates.

`kamu-money-core` remains a version dependency, never a manifest path.
Developer and ordinary container tests inject the local normalized package.
`gate-pg-release` disables that patch and proves registry resolution.

The lane is `publish = false`. `kamu-money-pg` is a package and release
identity, but not a crates.io artifact: Cargo packages do not carry the root
pgrx patch needed by its `yb-pg15` feature.

## Names

| Surface | Name | Reason |
| --- | --- | --- |
| Cargo package and directory | `kamu-money-pg` | Repository and release identity |
| Control file and SQL extension | `kmoney` | Unquoted PostgreSQL identifier |
| Library, shared object, `module_pathname` | `kmoney` | One SQL-side artifact name |
| Per-currency SQL types | `kmoney_usd` … (178, generated) | The type IS the currency; no cross-currency operator exists |
| Heterogeneous SQL type | `kmoney_mixed` | Currency carried per value; no arithmetic |

The control-file stem determines the extension name. Treat SQL type names and
both storage layouts (16-byte pinned, 18-byte mixed) as migration-sensitive
public interfaces.

## Layering

```text
PostgreSQL / pgrx ABI
        |
        v
src/ffi/       raw datum access, memory contexts, C-visible symbols
        |
        v
src/safe/      payloads, validation, pinned contract, rendering
        |
        v
kamu-money-core exact arithmetic and canonical text
```

All unsafe syntax is confined to `src/ffi/` and enforced by a Syn-based hygiene
test. `src/safe/` owns semantics and accepts ordinary values or fixed byte
arrays, not unproved raw pointers.

## Payloads and unsafe warranty

The two families use different fixed payloads:

```text
pinned (kmoney_<code>, 16 bytes):
bytes  0..16   signed i128 canonical units, little-endian

mixed (kmoney_mixed, 18 bytes):
bytes  0..16   signed i128 canonical units, little-endian
bytes 16..18   ISO 4217 numeric code, little-endian
```

The Rust payload is byte-backed and has alignment 1. It does not create an
`&i128` from PostgreSQL memory, whose alignment is weaker than Rust requires for
`i128`.

Before semantic use, each family's validator checks:

- exact payload width;
- the canonical money domain;
- for the mixed payload only, an assigned ISO numeric code. A pinned payload
  stores no code, so there is nothing else that could be wrong with it.

The ABI warranty is intentionally narrow:

- catalog entries report each type's own fixed `typlen` (16 pinned, 18 mixed),
  pass-by-reference, byte alignment, and plain storage;
- pgrx calls the conversion traits only for their registered OIDs;
- non-null scalar and array datums expose the registered fixed width;
- FFI allocation uses the active PostgreSQL memory context;
- cleanup that must survive a PostgreSQL error does not depend on Rust
  destructors running after pgrx translates the error.

Miri proves only the safe payload module. Live catalog, scalar, array, binary,
corruption, PostgreSQL-major, and YugabyteDB tests cover the foreign ABI that
Miri cannot model.

## SQL semantics

- A pinned type checks no currency anywhere: `kmoney_usd + kmoney_idr` has no
  operator to resolve and fails while the query is parsed. Input accepts the
  bare amount and the tagged form, refusing a tag that names another currency;
  output is bare, because the column's type carries the currency.
- `kmoney_mixed` supports equality only. It has no ordering, arithmetic, or
  `sum`, so unsupported computation fails at planning rather than after reading
  rows. Conversion to a pinned type goes through text, whose input check proves
  the tag.
- Each `sum(kmoney_<code>)` uses a 256-bit transition state and checks the money
  domain only when finalizing. Partial aggregation therefore remains
  order-independent.
- Division returns quotient and residue together.
- Allocation borrows the pgrx array, checks its length before iterating, and
  caps the number of parts before materializing weights.
- Text input/output, arithmetic, allocation, and stable hashing delegate to
  `kamu-money-core`.
- Binary send uses each type's validated payload. Binary receive exists on
  BOTH families: one shared raw symbol serves every pinned declaration — the
  payload is currency-less, so the `RETURNS` clause of each generated
  `CREATE FUNCTION` is what types the result — and every recv validates
  exactly as its type's text input does. Without RECEIVE, a binary `COPY`
  dump would be write-only and a `binary = true` logical-replication
  subscription could never complete its initial sync, and PostgreSQL offers
  no `ALTER TYPE ... RECEIVE` to add it later.
- Every refusal carries its SQLSTATE: `22P02` for refused text (including a
  wrong tag), `22003` for a magnitude outside the domain, `22P03` for bytes
  that denote no value (including a forged aggregate state), `22012`/`22023`
  for impossible division and allocation arguments, and `XX001` when bytes
  already stored in a column fail validation on the way out — the one class
  that genuinely is "should never happen". The codes are frozen contract,
  pinned by the `12-errors` suite.

There is deliberately no cast to PostgreSQL `numeric`.

### What a schema designer must know

No money type carries a btree or hash operator class. The absent
default-opclass ordering is the one surface YugabyteDB's planner would not
resolve for a custom type, and its absence is what keeps stored values
byte-exact there. The consequences are loud, never silent — each fails at plan
time:

- no `ORDER BY`, `min()`/`max()`, `DISTINCT`, `GROUP BY`, `UNION`
  deduplication, merge join, value index, `PRIMARY KEY`, or `UNIQUE` on a
  money column;
- comparisons work as sequential-scan predicates only and never push down to
  DocDB, so every candidate row ships to the backend — a performance cliff,
  not a wrongness;
- money is a VALUE, not a KEY. Top-N and percentile reporting belong on a
  numeric projection the application maintains, or in the application itself.

`kmoney_<code>_hash` is `IMMUTABLE` and returns `int4`, so a functional index
on it is creatable — and would go silently stale if a release ever bumped
`STABLE_HASH_VERSION`, because an existing index is not recomputed. Treat the
hash as a reconciliation checksum; do not index it.

### What a binary client must know

A pinned column's binary form is 16 **little-endian** bytes — the byte order
is fixed by the codec, not the platform, and it is the opposite of
PostgreSQL's network-order convention for built-in types. The currency is
resolved from the type OID in `RowDescription`; custom-type OIDs are assigned
per database, so a client maps OID → currency by querying `pg_type` by
`typname` at connection start, never by hardcoding an OID observed in one
environment. The bundled Rust adapters sidestep all of this deliberately:
they reject native OIDs and read through `::text`.

## Verification ladder

| Layer | Command or suite | Claim |
| --- | --- | --- |
| Formatting, Clippy, docs, deny | `just pg gate-offline` | Rust and repository policy without a database |
| Safe payload | hygiene tests and Miri | Width, byte order, code, currency, domain |
| PostgreSQL majors | `just pg test-pg-all` | Catalog, SQL semantics, binary I/O on PG15–18 |
| Portable driver path | `just pg test-pg-driver` | postgres-types and sqlx against native columns |
| YB image controls | `just pg yb-image-selftest` | Unknown and moved tags fail closed |
| Stock/YB equivalence | `just pg yb-ab` | Same SQL cases and golden output |
| Cluster behavior | release gate suites | Every node, tablet split, concurrency, replica, restore |
| Developer lane gate | `just gate-pg` | Offline checks, PG15–18, and portable database adapters |
| Repository pre-push gate | `just gate-all` | Public workspace plus developer lane gate |
| Native YB release proof | `just pg gate-pg-release` | From-source native build, byte-exact A/B against upstream PG15, ported case suite |
| YB deployment suites | `just pg test-yb-deployment` | Multi-node, read replica, concurrency, dump and restore |

[`kamu-money-pg/tests/pg_regress/COVERAGE.md`](kamu-money-pg/tests/pg_regress/COVERAGE.md)
maps every `#[pg_test]` to a portable SQL case or a reasoned
`NOT-PORTABLE` entry. Hygiene tests check both directions, required files,
golden labels, and orphan cases.

The release gate resolves one immutable YugabyteDB base image, builds one node
image, extracts the artifact from that image, and passes the same identities to
every suite. It also checks shipped bytes for benchmark-only probe symbols.

pgrx's raw generated SQL is not byte-reproducible because object order and
source-position comments can change. `schema-hash` strips provenance comments,
sorts objects, and compares the normalized schema. Release proof extracts the
SQL from the built image instead of regenerating a lookalike.

## Supported build and release model

The pgrx fork is pinned by tag and lockfile. Its `yb-pg15` changes are
feature-gated; stock PostgreSQL builds use the same dependency without that
feature. A YugabyteDB image change must pass the header probe and full release
gate before its digest is recorded.

The node-image target is a validation fixture and a source pattern for
consumers. This repository does not publish a production container image.
Deploying organizations build and own their artifact identity.

A GitHub release may use `kamu-money-pg-vX.Y.Z`. The release workflow verifies
the manifest and stops before crates.io.

## Known limits

- The `pt-immer/pgrx-yugabytedb` fork is maintained by this project.
- Certified against `yugabytedb/yugabyte:2025.2.5.1-b1`, the pinned image every
  suite boots. Other versions are not certified rather than known-broken: any
  YugabyteDB whose PostgreSQL fork the pgrx fork supports should work, and
  re-pinning plus a green `just pg gate-pg-release` is what turns that into a
  claim.
- Same-version dump/restore is gated. A two-version rolling YugabyteDB upgrade
  has not been rehearsed.
- Managed platforms that reject third-party native extensions require the
  canonical-text adapter instead.
- RPO, RTO, backup cadence, rollout authority, and incident response belong to
  the consuming platform.
- Benchmarks are comparative signals, not machine-independent pass/fail
  thresholds.

See the [YugabyteDB runbook](kamu-money-pg/yb/RUNBOOK.md) for adoption,
diagnosis, deployment order, and rollback cutoffs.
