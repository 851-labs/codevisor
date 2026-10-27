import { describe, expect, it } from "vitest"

import { run } from "../server-context.js"
import { makeServices } from "../test-support.js"
import { sandboxWorkPending } from "./sandbox-feature.js"
import { makeSandboxRecordStore } from "./sandbox-store.js"

describe("background sandbox work", () => {
  it("runs once the Sandboxes flag is on, or while sandboxes it already made still exist", async () => {
    const { services } = await makeServices("server-a")
    const records = makeSandboxRecordStore(services.db)
    const turnOn = () =>
      run(
        services.db.mergeSyncEntries("client-preferences", [
          {
            key: "featureFlags.sandboxes",
            value: true,
            timestamp: { wallMs: 1, counter: 0, deviceId: "mac" }
          }
        ])
      )

    const idle = await sandboxWorkPending(services.db, records)
    await records.put({
      id: "left-over",
      provider: "e2b",
      name: "Left over",
      projectId: "project-1",
      state: "ready",
      createdAt: "2026-10-27T00:00:00.000Z"
    })
    const leftOver = await sandboxWorkPending(services.db, records)
    await records.remove("left-over")
    await turnOn()
    const flagged = await sandboxWorkPending(services.db, records)

    expect([idle, leftOver, flagged]).toEqual([false, true, true])
  })
})
