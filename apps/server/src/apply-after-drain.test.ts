import { expect, it, vi } from "vitest"
import { applyAfterDrain } from "./apply-after-drain.js"
import { idleRestartCoordinator } from "./test-support.js"
import type { RestartDrainState } from "@codevisor/api"

it("does not install an update when its pending drain is cancelled", async () => {
  const drain = Promise.withResolvers<RestartDrainState>()
  const restart = { ...idleRestartCoordinator(), begin: vi.fn(() => drain.promise) }
  const publish = vi.fn()
  const apply = vi.fn(async () => {})
  const applying = applyAfterDrain(restart, {}, publish, apply)
  expect(restart.begin).toHaveBeenCalledOnce()
  expect(apply).not.toHaveBeenCalled()
  drain.resolve({ state: "idle", remaining: 0, startedAt: "2026-01-01T00:00:00.000Z" })
  await applying
  expect(publish).not.toHaveBeenCalled()
  expect(apply).not.toHaveBeenCalled()
})
