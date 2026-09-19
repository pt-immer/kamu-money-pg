# Changelog

## 0.2.1 — Unreleased

- Extract the PostgreSQL/YugabyteDB extension into its own public repository.
- Resolve kamu-money-core exclusively from the committed crates.io lockfile.
- Own extension tooling, policy checks, CI, builder images and releases here.
- Bound correctness-harness memory and fail source scans on unreadable inputs.
- Replace yanked chacha20 and vulnerable smol-toml in the locked tooling graphs.
- Require complete, closed-manifest verification before release checks or artifact copies.

## 0.2.0

Imported from kamu-public-crates. See [IMPORT.md](IMPORT.md) for the source commit
and preserved history.
