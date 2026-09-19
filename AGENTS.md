# Agent guide — kamu-money-pg

This standalone workspace contains the unpublished `kamu-money-pg` pgrx extension, the pgrx-free
artifact authority under `tools/artifact`, and the pgrx-free `hygiene` crate. `CLAUDE.md` and
`.github/copilot-instructions.md` are symlinks to this file.

## Boundaries

- `kamu-money-core` resolves exclusively from crates.io at the committed lockfile
  version. Never inject local or git core patches. Driver tests come from that
  same registry package; missing packaged tests are errors.
- The workspace patches pgrx and pgrx-pg-sys to the reviewed YugabyteDB fork.
  Keep that fork and the exact cargo-pgrx version aligned. Re-measure upstream
  differences before changing the fork tag.
- Never use workspace-wide `--all-features`: select one PostgreSQL major.
  Keep PostgreSQL 15–18 and the pinned YugabyteDB image supported.
- All unsafe syntax belongs in `kamu-money-pg/src/ffi/`. Safe payload and semantic
  code lives in `src/safe/`; Miri covers payloads and live tests prove the ABI.
- Persisted hashes use `kamu_money_core::advanced::stable_hash`.
- `tools/artifact` is the pgrx-free authority for the closed extension triplet. Verified products
  own the exact library, control and SQL bytes; release checks and copied installs consume those
  products without exporting verified filesystem paths or boolean proof flags.
- Preserve SQL names, SQLSTATEs and byte layouts. They are migration-sensitive
  public interfaces. The workspace remains `publish = false`.

## Tooling and checks

`.config/dev-tools.json` supplies CI tool pins. Rust channel/MSRV and pgrx
versions must agree with the files the actual tools read. Include rust-src.
Builder images pin a digest; cache keys include all dependency-layer inputs.

Run `just gate` before pushing. Before an extension release, also run
`just gate-pg-release`: native YugabyteDB build, forced dependency recompilation,
byte-exact PostgreSQL 15 comparison and SQL regression cases. Deployment tests
remain separately available through `just test-yb-deployment`.

Nextest runs ordinary hygiene tests; doctests run explicitly. Retries stay off.
The in-backend tests use pgrx. Every negative control must be reached by a
required CI job, not merely listed in an unused local aggregate.

Use `scripts/pgrx.sh` for extension build/schema/test commands: pgrx has no
`--locked` flag, so the helper locks its Cargo subprocesses. Direct Cargo
build/test/metadata commands use `--locked`. Update dependencies deliberately.

The default YugabyteDB scratch root is locked. Set a unique `KMONEY_RUN_ROOT`
for independent concurrent runs. Cleanup is scoped to each run, never a broad
Docker prune. Preserve immutable image identity through each complete proof.

## CI and commits

One PR gate, `ci-success`, gathers every job and permits no skipped jobs.
Use job-level conditions when needed; never workflow path filters on a required
check. Third-party actions use full commit IDs. CI calls the same recipes as
local validation. The builder publisher is a separate, non-gating workflow.

Branches use `<type>/tdkc-<n>-<slug>`. Every commit is GPG-signed, with a lowercase
Conventional Commit subject and its lowercase Jira key as a standalone paragraph.
PRs require review; do not bypass branch protection. Releases use
`kamu-money-pg-vX.Y.Z` from main after the full release proof. Never publish this
workspace to crates.io. Update manifests and CHANGELOG.md for source/manifest
changes; preserve original history in the source repository named by IMPORT.md.

Keep README.md, DESIGN.md, runbooks, recipes, tests and this guide consistent.
