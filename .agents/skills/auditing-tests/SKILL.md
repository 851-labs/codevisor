---
name: auditing-tests
description: Use when sweeping, pruning, deleting, or consolidating tests that already exist - when asked to find low-value, implementation-coupled, duplicative, or assertion-free tests, the test-only production code they keep alive, or to run a test-pruning campaign over a package or subsystem.
---

# Auditing tests

Adapted from OpenClaw's `test-audit` skill (MIT,
https://github.com/openclaw/openclaw/tree/main/.agents/skills/test-audit).
This skill decides whether a test that already exists still earns its place.
The `writing-tests` skill owns the rest: the authoring gate for new or changed
tests, the junk patterns both skills share, how to write a deterministic test,
and the commands that run them. Read it first.

Two modes, one value bar. Audit mode runs focused sweeps of tests that
re-assert source, duplicate stronger proof, couple behavior to implementation,
or keep test-only production seams alive. Continue broad audits as separate
coherent follow-up PRs; optimize for confidence, not deletion count. Campaign
mode prunes one whole subsystem's test surface (every test file a package or
app area owns); before starting one, read [CAMPAIGN.md](CAMPAIGN.md).

## Value bar

Tests justify their maintenance cost by protecting behavior, a credible
regression, or an independently meaningful contract. In an audit, an existing
test that must change for behavior-preserving source reorganization is suspect,
not automatically deletable; the authoring gate still rejects new ones.

Before judging a candidate, read the complete test and production owner, its
entry point, callers, callees, sibling implementations, overlapping tests,
coverage configuration, and relevant history (`git log -S <symbol>` finds the
commit that removed the last production caller). Read the `writing-tests`
skill and any skill that covers the code's area (such as `writing-code` for
Swift isolation rules). When the test claims dependency-backed behavior,
inspect the dependency source or types directly; use the
`using-reference-repos` skill for upstream code.

## Discovery

Keep discovery read-only and report evidence before editing. For broad scope,
run parallel read-only discovery lanes:

- the server (`apps/server`);
- TypeScript packages (`packages/*` except `packages/swift`), watching for
  adapter-local replays across `adapter-*`;
- Swift (`packages/swift`, `apps/macos`, `apps/ios`, `apps/shared`);
- other apps and tooling (`apps/cloud`, `apps/www`, `scripts/`);
- a cross-cutting pattern sweep: assertion-free tests, self-comparisons,
  source greps, and exported symbols whose only non-local references are in
  tests.

Outside campaign mode, prefer a few high-confidence candidates over a large
speculative inventory. Hunt for the junk patterns listed in `writing-tests`. Confirm
every "no production caller" claim with `git grep -n <symbol>` yourself before
editing; for Swift, grep outside `/Tests/` and build directories, and let the
compiler settle common names.

## Retention bar

Keep a test when it independently enforces a public API, protocol, config,
migration, storage, security, platform, default, prompt-byte, cross-language
wire (TypeScript server and Swift client), package, release, or architecture
contract. Also keep:

- call ordering when order is observable behavior;
- regressions with a credible failure mode;
- source inspection when it is the cheapest independent guard: it fails when
  the contract changes (the user-facing key, byte, or path) and survives an
  identifier-only refactor;
- documented test seams with a real production path, such as DEBUG-only
  seeding hooks for states that are persisted but otherwise unreachable, and
  reset hooks for module-level caches;
- per-copy tests of production code that is deliberately duplicated;
- a retained test that fails on the baseline: treat it as a possible product
  bug, reproduce it, and repair the owner rather than deleting it.

Static or slow is not a deletion reason. A test that resembles implementation
may still be the independent contract; prove otherwise before removing it.

## Candidate evidence

Record every field below before editing. A missing field means the candidate is
not ready for deletion:

- exact test name and location;
- what failure it can actually detect;
- non-test callers of the covered production or support seam;
- stronger remaining owner-boundary proof, or why no proof is needed;
- relevant history and the reason the test or seam exists;
- production or test-support deletion unlocked;
- coverage-threshold impact;
- risk and the focused validation command.

## Edit shape

Choose one coherent owner-boundary batch. Delete obsolete test-only exports,
globals, wrappers, and dead production paths instead of preserving aliases.
Move retained regressions to their canonical owners; when a deleted test also
held an unrelated real assertion (a protocol-version pin), keep that assertion
as its own named test. Consolidate repeated package or dependency assertions
into one generic contract.

Many packages enforce coverage thresholds in `vitest.config.ts` (`apps/server`
and much of `packages/agent-runtime` at 80%). Deleting a coverage probe
without its code fails that gate. Delete the dead code with the test, or
simplify the unreachable branch first. Do not lower a threshold or add a
coverage exclusion to land a deletion. `packages/agent-runtime` also runs the
`adapter-acp`, `adapter-claude`, and `adapter-codex` suites for its coverage,
so a test in an adapter package may be the owner proof for agent-runtime code.

Prefer net-negative production LOC. Do not add replacement tests that restate
the same implementation, and do not convert uncertain candidates into cleanup
to increase deletion counts.

## Validation

Never edit source or tests while a test run is still running in the checkout.

1. Run the steps under "Run the tests" in the `writing-tests` skill for every
   touched package: the smallest owner and sibling tests, coverage, typecheck,
   then format, lint, and the size ratchet.
2. For removed source greps or plan assertions, run the executable script or
   dry run that owns the real contract.
3. Inspect `git diff --numstat`; report production and tooling separately from
   tests and test support.
4. After final audit edits, review the diff with your harness's code review if
   it has one (in Claude Code, the built-in `code-review` skill).

`bun run check`, the pre-push hook, and Build on main are described in the
same section of `writing-tests`; allow them time rather than bypassing them.

## Landing and continuation

Commit, push, open a PR, or land only when authorized. Branch from current
`main`, and follow the `working-linear-tickets` skill when the work has a
ticket; `AGENTS.md` describes the two ways to ship. Land
one coherent PR at a time; after landing, refresh from current `main` and
rerun read-only discovery for the next high-confidence batch.

## Handoff

Report:

- root cause and removed low-value categories;
- production owner simplifications;
- retained false positives and why they remain valuable;
- focused and full proof actually run;
- production versus test LOC;
- PR and merge state;
- named follow-ups.
