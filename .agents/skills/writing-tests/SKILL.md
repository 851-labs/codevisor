---
name: writing-tests
description: Use when adding or changing a test or test fixture in TypeScript, Swift, or scripts, when reviewing new or changed tests, when a test is flaky, order-dependent, or timing-dependent, when test runtime needs to come down, or when deciding which command runs a test, its coverage, or the full checks.
---

# Writing tests

Every new or changed test answers two questions. Does it earn its place? The
[authoring gate](#authoring-gate) decides. Is it deterministic and fast? The
rest of this skill covers that. Sweeping or pruning tests that already exist
is the `auditing-tests` skill's job.

Treat a flaky test as a defect. The same inputs must produce the same result,
regardless of machine speed, scheduler order, current date, or other tests.
Preserve useful behavior coverage when replacing a flaky or slow test.

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
the gate unless the retention bar in the `auditing-tests` skill names the
contract it independently guards. A test that would break under behavior-preserving
refactoring is asserting implementation, not behavior; rewrite it at the
owning boundary before landing it.

Bug regression tests must fail on the pre-fix code for the intended reason and
pass after the owner-boundary repair. A regression test that never demonstrably
failed proves the mock, not the fix. One regression at the owner boundary
covers the bug; do not replay the same scenario at every layer it crosses.

## Junk patterns

The authoring gate rejects a new test that matches one of these, and audits
(the `auditing-tests` skill) hunt for existing tests that do.

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

## Design the test

1. Identify the observable behavior and the smallest component that owns it.
2. List uncontrolled inputs: clocks, task scheduling, randomness, network,
   filesystem state, process environment, locale, and global caches.
3. Control those inputs through existing seams, or introduce a small dependency
   at the boundary. Keep production defaults unchanged.
4. Prefer a unit test with an in-memory fake. Use real sockets, databases,
   processes, browsers, or native rendering only when that boundary is the
   behavior under test. Keep those integration cases focused.

## Control time

- Test timeout, debounce, retry, expiration, animation, and backoff behavior
  with a fake clock or an injected scheduler. Assert immediately before the
  deadline, advance across it, then assert the result.
- Freeze the date when comparing timestamps or calendar behavior. Set explicit
  timestamps for filesystem ordering; do not sleep between writes.
- Separate elapsed time from wall time. A budget clock must be monotonic.
- Do not shorten production timeouts to make a test fast. Do not enlarge a
  timeout or add retries to hide a race.

For Vitest, install fake timers before starting the operation. Attach rejection
handlers before advancing time, and restore timers and mocks in cleanup:

```ts
vi.useFakeTimers()
try {
  const completed = vi.fn()
  const operation = startOperation().then(completed)
  await vi.advanceTimersByTimeAsync(999)
  expect(completed).not.toHaveBeenCalled()
  await vi.advanceTimersByTimeAsync(1)
  await operation
  expect(completed).toHaveBeenCalledOnce()
} finally {
  vi.useRealTimers()
}
```

Use `vi.useFakeTimers({ toFake: ["Date"] })` when only the date needs control
and real I/O must continue. For Effect-managed time, use Effect's test clock.
Do not mix a fake global scheduler with live socket or subprocess readiness;
inject the application's clock or timer dependency instead.

In Swift, inject a clock or an async sleeper backed by continuations. Wait for
the sleeper to register before advancing it. Make cancellation resume pending
continuations exactly once. Prefer existing manual clocks and gates in the
test target over another bespoke implementation.

## Synchronize on events

- Await the operation's returned task/promise, a readiness callback, a stream
  event, or an explicit test-controlled gate.
- Register listeners before triggering an event. Buffer events that may arrive
  before the consumer starts waiting.
- For fixtures written by another executor, recheck the predicate after
  installing its observer to close the read/subscription gap. Protect the
  fixture's state with an actor or lock.
- Test races by holding operation A, starting B, and explicitly releasing A.
  Exercise the relevant completion orders without relying on scheduler luck.
- For a negative assertion, first prove the relevant work has finished or is
  blocked at the intended gate. Waiting briefly proves neither.
- Never synchronize with fixed sleeps, repeated `Task.yield()`, a fixed number
  of microtask flushes, timed run-loop drains, or an arbitrary number of polling
  attempts.
- For hosted AppKit/SwiftUI tests, explicitly lay out the view before measuring
  or rendering it. Await actual responder changes for asynchronous focus and
  observable state changes for actions. Give each test its own window and set
  the locale and appearance when expectations depend on them.
- Real I/O integration tests may retain a runner timeout as a deadlock guard.
  That guard is not the timeout being tested and must not determine the expected
  result. Prefer completion events over polling. Always remove listeners and
  cancel watchdogs when an operation completes.

## Isolate state and clean up

- Create a fresh fixture per test. Use unique temporary directories and let the
  OS allocate listening ports (`0`). A port released before reuse is not reserved.
- Keep external services and user configuration out of ordinary tests. Supply
  explicit environment, credentials, paths, locale, and deterministic responses.
- Seed generated input when its values affect expectations. Unique IDs used
  only for isolation need not have fixed values.
- Restore environment variables, global mocks, clocks, and singleton state.
- Register cleanup as soon as a resource is created. Await task cancellation,
  server closure, and process termination, including after assertion failures.
- Never disable parallelism to mask shared-state races; remove the shared
  mutable state. Bound aggregate worker concurrency when real integrations
  would otherwise oversubscribe the machine.
- Vitest test files share loaded modules within a worker
  (`@codevisor/vitest-config`). Name a file `*.isolated.test.ts` when it uses
  `vi.mock`, `vi.doMock`, or `vi.resetModules`. Don't register hooks at the
  top level of a support module; register cleanup with `onTestFinished` when
  the resource is created, or put per-file hooks in the package's
  `src/test-setup.ts`. Lint enforces both (`codevisor/isolated-module-mocks`,
  `codevisor/no-import-time-test-hooks`). Test order is shuffled; reproduce
  an order failure with the printed seed (`--sequence.seed=<seed>`).
- After overriding a module-level `vi.fn` with `mockImplementation`, reset it
  in cleanup with `mockReset`/`vi.resetAllMocks`, which restore the original
  implementation. `clearAllMocks` only clears calls.
- TCA's `TestStore` and `withMainSerialExecutor` install a process-wide Swift
  executor override. Run the full Swift suites with `bun run swift:test`, which
  isolates those suites from other tests without disabling parallelism. Register
  new suites using either API in `packages/swift/main-serial-executor-suites.json`;
  `scripts/test-swift.mjs` reads it, and its regression test checks that every
  such suite is included. Do not combine them with unrelated suites in a direct
  `swift test` invocation.

## Keep the feedback loop fast

- Measure individual test and fixture durations before optimizing.
- Remove artificial waits. Reuse immutable parsed fixtures when safe; do not
  share mutable servers or databases merely to avoid setup.
- Use the smallest input that crosses the behavior boundary. Large inputs are
  justified for size limits, truncation, pagination, and complexity regressions.
- Split broad scenarios into focused tests when this avoids unrelated setup.
  Keep a small integration test for wiring already covered by unit tests.
- Check operation counts or bounded output for algorithmic regressions. Put
  wall-clock performance comparisons in benchmarks, outside correctness tests.

- Real Chrome runs only in `packages/automation/src/*.chrome.test.ts`
  (`bun run test:chrome`; CI runs it when `packages/automation` changes, and Nightly runs it daily), never in
  `bun run check`. Put a test there only when it needs a real rendering engine
  (accessibility tree, document order, trusted input, frames, real CDP
  events); prove tab and session bookkeeping with the CDP fakes in
  `browser-tab-lifecycle.test.ts` or `browser-tab-routing.isolated.test.ts`. Chrome
  suites start the browser once per file in `beforeAll`, and each test uses
  its own agent session.

## Existing Codevisor fixtures

- `packages/swift/TestSupport`: `TestClock` advances elapsed time;
  `TestSignal` acknowledges operations; `awaitObserved` waits for observable
  state; `TrackedStream` acknowledges handling the previous stream item.
- `packages/swift/Autocomplete/Tests/AutocompleteTests/FocusTestWindow.swift`:
  acknowledges native responder changes without sleeping or polling.
- `apps/server/src/changes-test-support.ts`: database writes and observable
  fixtures notify condition waiters. A predicate must read state that emits
  these notifications; unrelated state needs its own completion event.
- `packages/adapter-claude/src/test-support.ts`: wait for actual input delivery
  or stream consumption instead of flushing microtasks.
- `packages/worktrees/src/git-test-support.ts`: isolated Git configuration,
  immutable repository seeds, and automatic temporary-directory cleanup.
- `apps/cloud/test/cloud-test-support.ts`: acknowledge the Durable Object's
  disconnect handler before advancing resume expiry. Keep workerd's real
  alarms dormant and invoke the alarm explicitly under the controlled clock.

## Review and verify

Search changed tests **and their shared fixtures** for sleeps, polling loops,
real clock reads, tiny deadlines, random input, fixed ports, and leaked tasks.
Inspect each match; fake timer callbacks and production watchdogs are not
automatically defects.

Run the affected test target, then its typecheck and relevant coverage checks
(see [Run the tests](#run-the-tests)). Run the full applicable suites after
broad changes. For repaired races, repeat
the affected suite with different test order/seed and ordinary parallelism;
do not enable retries. A passing repetition is supporting evidence, not proof
of determinism. Explain which source of nondeterminism was removed.

Do not delete coverage, skip tests, weaken assertions, or lower coverage floors
to obtain a green run. Replace redundant tests only after identifying where
the same behavior remains covered. Report environmental blockers and remaining
known risks candidly; do not claim that a passing run proves no flakes exist.

## Run the tests

Never edit source or tests while a test run is still running in the checkout.
A new worktree already has its dependencies: the post-checkout hook installs
them. If `node_modules` is missing, run `bun install --frozen-lockfile` with
Node on PATH (see the `running-dev` skill).

1. Run the smallest owner and sibling tests: from the package directory,
   `bunx vitest run <path>` (add `-t "<test name>"` for one test in the
   file); for scripts, `node --test <file>`; for Swift
   suites, `swift test --package-path packages/swift --filter <Suite>` (suites
   listed in `packages/swift/main-serial-executor-suites.json` must run through
   `bun run swift:test` instead).
2. Run `bun run test:coverage` in each touched TypeScript package so coverage
   thresholds are checked.
3. Typecheck the touched packages:
   `bunx turbo run typecheck --filter=<package> ...`.
4. Run `bun run format:check`, `bun run lint`, `bun run ratchet:check`, and
   `git diff --check`.

`bun run check` runs every check your changes can affect against `HEAD`
(`bun run check -- --dry-run` lists them), including the Swift suites when
Swift changed. The pre-push hook runs the same plan against `origin/main`
without the Swift suites, and Build runs all of it on main after the merge; allow
them time rather than bypassing them. `bun run check:all` runs everything.

## References

- [Vitest: fake timers](https://vitest.dev/guide/mocking/timers)
- [Vitest: mocking dates](https://vitest.dev/guide/mocking/dates)
- [Google: sources of test flakiness](https://testing.googleblog.com/2020/12/test-flakiness-one-of-main-challenges.html)
- [Playwright: test isolation and behavior assertions](https://playwright.dev/docs/best-practices)
- [AppKit: update layout before inspecting it](https://developer.apple.com/documentation/appkit/nsview/layoutsubtreeifneeded%28%29)

The authoring gate and junk patterns are adapted from OpenClaw's `test-audit`
skill (MIT,
https://github.com/openclaw/openclaw/tree/main/.agents/skills/test-audit).
