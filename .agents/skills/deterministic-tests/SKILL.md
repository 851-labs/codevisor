---
name: deterministic-tests
description: Write, change, review, or debug Codevisor tests. Use whenever adding tests, changing test fixtures, investigating flaky failures, or optimizing test runtime in TypeScript, Swift, or scripts.
---

# Deterministic, fast tests

Treat a flaky test as a defect. The same inputs must produce the same result,
regardless of machine speed, scheduler order, current date, or other tests.
Preserve useful behavior coverage when replacing a flaky or slow test.

## Before writing a test

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

Run the affected test target, then its typecheck and relevant coverage checks.
Run the full applicable suites after broad changes. For repaired races, repeat
the affected suite with different test order/seed and ordinary parallelism;
do not enable retries. A passing repetition is supporting evidence, not proof
of determinism. Explain which source of nondeterminism was removed.

Do not delete coverage, skip tests, weaken assertions, or lower coverage floors
to obtain a green run. Replace redundant tests only after identifying where
the same behavior remains covered. Report environmental blockers and remaining
known risks candidly; do not claim that a passing run proves no flakes exist.

## References

- [Vitest: fake timers](https://vitest.dev/guide/mocking/timers)
- [Vitest: mocking dates](https://vitest.dev/guide/mocking/dates)
- [Google: sources of test flakiness](https://testing.googleblog.com/2020/12/test-flakiness-one-of-main-challenges.html)
- [Playwright: test isolation and behavior assertions](https://playwright.dev/docs/best-practices)
- [AppKit: update layout before inspecting it](https://developer.apple.com/documentation/appkit/nsview/layoutsubtreeifneeded%28%29)
