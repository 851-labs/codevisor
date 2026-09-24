---
name: test-audit
description: Gate new tests and audit existing ones for low value. Use whenever writing, changing, reviewing, or sweeping tests, or when asked to find low-value, implementation-coupled, or duplicative tests and the test-only production code they keep alive.
---

# Test Audit

Adapted from OpenClaw's `test-audit` skill (MIT,
https://github.com/openclaw/openclaw/tree/main/.agents/skills/test-audit).
This skill decides _whether_ a test earns its place. The `deterministic-tests`
skill decides _how_ to write it; apply both.

Three modes, one value bar. Authoring mode gates every new or changed test at
write time. Audit mode runs focused sweeps of tests that re-assert source,
duplicate stronger proof, couple behavior to implementation, or keep test-only
production seams alive. Continue broad audits as separate coherent follow-up
PRs; optimize for confidence, not deletion count. Campaign mode prunes one
whole subsystem's test surface (every test file a package or app area owns);
before starting one, read [CAMPAIGN.md](CAMPAIGN.md).

## Authoring gate

Before adding any test, answer four questions; a missing answer means do not
add it yet:

1. What observable behavior, invariant, or independent contract does it protect?
2. What credible regression makes it fail?
3. Why does existing coverage not already catch that failure? Each contract has
   one primary test owner at the strongest boundary; another layer needs its
   own distinct risk, such as a transport or lifecycle failure the owner cannot
   reach. Prefer extending a table-driven case or shared fixture over a
   near-duplicate test; consolidate duplicated setup in the same change.
4. Does it need a production seam (export, flag, wrapper, injection hook) that
   no production caller needs? If yes, move the test to the real boundary
   instead.

Then check the test against every [junk pattern](#junk-patterns); a match fails
the gate unless the [retention bar](#retention-bar) names the contract it
independently guards. A test that would break under behavior-preserving
refactoring is asserting implementation, not behavior; rewrite it at the
owning boundary before landing it.

Bug regression tests must fail on the pre-fix code for the intended reason and
pass after the owner-boundary repair. A regression test that never demonstrably
failed proves the mock, not the fix. One regression at the owner boundary
covers the bug; do not replay the same scenario at every layer it crosses.

## Junk patterns

The shared checklist for both modes: the authoring gate rejects a new test that
matches one, and audits hunt for existing tests that do.

- assertion-free coverage probes (no `expect`, `#expect`, or `XCTAssert`, or
  only `toBeDefined()` / `not.toThrow()` on a call that cannot throw);
- self-comparisons and identity copiers, such as comparing two calls of a pure
  template or round-tripping synthesized `Codable` through the same coder;
- copied fixtures, inventories, manifests, or export lists, such as
  `allCases.count` checks or `CaseIterable` conformances only a test uses;
- exact source, import, or string greps;
- private predicate or call-shape tests duplicated at real boundaries;
- duplicate invocations of the same contract;
- adapter-local replays of shared helpers (`@codevisor/agent-runtime` and
  `@codevisor/adapter-acp` helpers re-tested inside another `adapter-*`);
- tests whose only purpose is preserving test-only exports, globals, or
  wrappers;
- dead production code whose only callers are tests;
- expected values produced by the helper or renderer under test;
- mocks that implement the asserted behavior, or one identical mock standing in
  for different APIs;
- fixtures that supply the receipt, admission, or callback ordering the owner
  should produce, or persistence asserted against a store the path never
  writes;
- capability tests that restate declared flags or computed constants (a
  `var isX: Bool { true }`) instead of exercising what the flag promises;
- negative controls that pass for an unrelated reason, such as a denial from a
  different guard, a rejection the production path never reaches, or a
  platform-specific failure (`/proc` missing on macOS);
- names or fixtures that promise more than the input exercises, such as an
  "immovable pane" test asserting the pane is movable.

## Value bar

Tests justify their maintenance cost by protecting behavior, a credible
regression, or an independently meaningful contract. In an audit, an existing
test that must change for behavior-preserving source reorganization is suspect,
not automatically deletable; the authoring gate still rejects new ones.

Before judging a candidate, read the complete test and production owner, its
entry point, callers, callees, sibling implementations, overlapping tests,
coverage configuration, and relevant history (`git log -S <symbol>` finds the
commit that removed the last production caller). Read the `deterministic-tests`
skill and any area skill (`vnc-change`, `ios-development`) that owns the code.
When the test claims dependency-backed behavior, inspect the dependency source
or types directly; use the `use-reference-repos` skill for upstream code.

## Discovery

Keep discovery read-only and report evidence before editing. For broad scope,
run parallel read-only discovery lanes:

- the server (`apps/server`);
- TypeScript packages (`packages/*` except `packages/swift`), watching for
  adapter-local replays across `adapter-*`;
- Swift (`packages/swift`, `apps/macos`, `apps/ios`, `apps/shared`);
- other apps and tooling (`apps/cloud`, `apps/screen-sharing-rig`, `apps/www`,
  `scripts/`);
- a cross-cutting pattern sweep: assertion-free tests, self-comparisons,
  source greps, and exported symbols whose only non-local references are in
  tests.

Outside campaign mode, prefer a few high-confidence candidates over a large
speculative inventory. Hunt for the [junk patterns](#junk-patterns). Confirm
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
and much of `packages/agent-runtime` at 100%). Deleting a coverage probe
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
Install dependencies (`bun install --frozen-lockfile`) in a fresh worktree
first.

1. Run the smallest owner and sibling tests: from the package directory,
   `bunx vitest run <path>`; for scripts, `node --test <file>`; for Swift
   suites, `swift test --package-path packages/swift --filter <Suite>` (suites
   listed in `packages/swift/main-serial-executor-suites.json` must run through
   `bun run swift:test` instead).
2. Run `bun run test:coverage` in each touched TypeScript package so coverage
   thresholds are checked.
3. Typecheck the touched packages:
   `bunx turbo run typecheck --filter=<package> ...`.
4. For removed source greps or plan assertions, run the executable script or
   dry run that owns the real contract.
5. Run `bun run format:check`, `bun run lint`, `bun run ratchet:check`, and
   `git diff --check`.
6. Inspect `git diff --numstat`; report production and tooling separately from
   tests and test support.
7. After final audit edits, run the `code-review` skill on the diff.

The `lefthook` pre-commit hook runs the full `bun run check`, including the
Swift suites and iOS build; allow it time rather than bypassing it.

## Landing and continuation

Commit, push, open a PR, or land only when authorized. Branch from current
`main`, and follow the `linear-ticket` skill when the work has a ticket. Land
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
