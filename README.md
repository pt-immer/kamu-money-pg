# kamu-money-pg

PostgreSQL and YugabyteDB extension for exact ISO 4217 money, built with pgrx.
The SQL extension is `kmoney`; it supplies per-currency types such as
`kmoney_usd` and the heterogeneous `kmoney_mixed` type.

Supports PostgreSQL 15–18 and the YugabyteDB image pinned in
[YB-PINNED.txt](kamu-money-pg/yb/YB-PINNED.txt).

## Development

Install Rust, Docker, Node.js/npm, jq and ShellCheck, then run:

```bash
just setup
just doctor
just pgrx-init /usr/bin/pg_config
just gate
```

`pgrx-init` needs PostgreSQL 18 development headers for the local Clippy and
rustdoc checks. Container tests own their PostgreSQL installations.
`just` lists every recipe. All commands run from this repository root.

`kamu-money-core` and its Rust driver adapters live in
[kamu-public-crates](https://github.com/pt-immer/kamu-public-crates).
This repository consumes only published core versions through its committed
`Cargo.lock`. No sibling checkout or local Cargo patch is supported.
Update the lock through `just core-relock` and review the resulting diff.

## Validation and releases

`just gate` checks repository hygiene, Clippy, docs, Miri, PostgreSQL 15–18,
and the Rust drivers on PostgreSQL and YugabyteDB. It needs Docker.
`just gate-pg-release` additionally rebuilds native YugabyteDB dependencies,
proves byte-exact equivalence with PostgreSQL 15, and runs the ported SQL cases.
`just test-yb-deployment` covers separate operational cluster behavior.

PRs run independent extension checks. Core publication does not trigger this
repository; dependency-update PRs carry integration validation.
Builder images are published by `publish-builder-image.yml` and pinned by
digest in `.config/builder-image`.

The extension is not published to crates.io. A `kamu-money-pg-vX.Y.Z` release
must name a matching manifest version on `main`, after the release proof passes.
The deployable artifact is the consumer-owned YugabyteDB node image.

See [DESIGN.md](DESIGN.md) for SQL/storage contracts,
[RUNBOOK.md](kamu-money-pg/yb/RUNBOOK.md) for operational steps,
and [IMPORT.md](IMPORT.md) for source provenance.

Dual-licensed MIT OR Apache-2.0. See [LICENSE-MIT](LICENSE-MIT) and
[LICENSE-APACHE](LICENSE-APACHE).
