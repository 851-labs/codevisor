import { expect, it, vi } from "vitest"

import { fleet } from "./infra/shared-accounts-test-support.js"
import { run, startWithApp } from "./test-support.js"

/// Starting the app kicks off a shared-account reconcile that writes credential
/// files under the harness home. Closing must drain it: a write landing after
/// shutdown races whatever tears that directory down — a restarting server, or
/// a test's own temp-directory cleanup (which surfaced as an intermittent
/// ENOTEMPTY while removing `<dataDir>/.codex`).
it("drains the in-flight shared-account reconcile before reporting the app closed", async () => {
  const machine = await fleet().machine("close-drain")
  const entered = Promise.withResolvers<void>()
  const release = Promise.withResolvers<void>()
  const order: Array<string> = []
  vi.spyOn(machine.shared, "reconcile").mockImplementation(async () => {
    entered.resolve()
    await release.promise
    order.push("reconcile")
  })

  const server = await startWithApp({ ...machine.services })
  // The reconcile is now genuinely in flight, not merely scheduled.
  await entered.promise

  const closing = run(server.close).then(() => {
    order.push("close")
  })
  // Release only once the close path has run everything it can without the
  // drain, so "reconcile" precedes "close" exactly when close awaited it.
  setImmediate(() => release.resolve())
  await closing

  expect(order).toEqual(["reconcile", "close"])
})
