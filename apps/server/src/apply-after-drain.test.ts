import { describe, expect, it } from "vitest"

import { applyAfterDrain } from "./apply-after-drain.js"
import { idleRestartCoordinator } from "./test-support.js"

describe("applyAfterDrain", () => {
  it("never publishes or applies an update whose drain was abandoned", async () => {
    const restart = idleRestartCoordinator()
    const calls: Array<string> = []
    await applyAfterDrain(
      { ...restart, begin: async () => restart.state() },
      {},
      () => calls.push("publish"),
      async () => {
        calls.push("apply")
      }
    )
    expect(calls).toEqual([])
  })

  it("cancels the drain when applying fails so prompts dispatch again", async () => {
    const restart = idleRestartCoordinator()
    const calls: Array<string> = []
    await applyAfterDrain(
      {
        ...restart,
        cancel: async () => {
          calls.push("cancel")
          return restart.state()
        }
      },
      {},
      () => calls.push("publish"),
      async () => {
        calls.push("apply")
        throw new Error("install failed")
      }
    )
    expect(calls).toEqual(["publish", "apply", "cancel"])
  })
})
