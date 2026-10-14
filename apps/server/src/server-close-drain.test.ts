import { expect, it, vi } from "vitest"

import { fleet } from "./infra/shared-accounts-test-support.js"
import { run, startWithApp } from "./test-support.js"

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
  await entered.promise

  const closing = run(server.close).then(() => {
    order.push("close")
  })
  setImmediate(() => release.resolve())
  await closing

  expect(order).toEqual(["reconcile", "close"])
})
