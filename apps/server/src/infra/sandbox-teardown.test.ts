import { describe, expect, it } from "vitest"

import { JOINED_DEVICE, sandboxHarness } from "./sandbox-test-support.js"

const request = { profileId: "profile-1", projectId: "project-1", name: "Spike box" }

const ready = async () => {
  const harness = await sandboxHarness()
  await harness.machines.create(request)
  await harness.machines.settled()
  return harness
}

describe("teardown robustness", () => {
  it("runs one teardown when two watch ticks overlap", async () => {
    const harness = await ready()
    harness.workspaces.splice(0)

    await Promise.all([harness.machines.watch(), harness.machines.watch()])

    expect(harness.removed).toEqual([JOINED_DEVICE])
    expect(await harness.machines.list()).toEqual([])
  })

  it("only watches machines that finished setting up", async () => {
    const harness = await sandboxHarness({ bootstrapExit: 1 })
    await harness.machines.create(request)
    await harness.machines.settled()

    await harness.machines.watch()

    expect(harness.toolCalls).toEqual([])
    expect((await harness.machines.list())[0]?.state).toBe("failed")
  })

  it("still records the failure when tearing down a failed setup fails too", async () => {
    const harness = await sandboxHarness({ project: { id: "elsewhere" } })
    harness.controls.removeFails = true

    await harness.machines.create(request)
    await harness.machines.settled()

    expect((await harness.machines.list())[0]).toMatchObject({
      state: "failed",
      error: "No project project-1 on this machine"
    })
  })

  it("marks an interrupted record failed even when its teardown can't reach the cloud", async () => {
    const harness = await sandboxHarness()
    harness.controls.removeFails = true
    await harness.records.put({
      id: "half",
      provider: "e2b",
      accountId: "account-1",
      name: "half",
      projectId: "project-1",
      state: "syncing",
      createdAt: "2026-10-23T00:00:00.000Z",
      deviceId: "device-half"
    })

    await harness.machines.sweep()

    expect((await harness.machines.list())[0]?.state).toBe("failed")
  })

  it("keeps a failure message for errors that aren't Error objects", async () => {
    const harness = await sandboxHarness()
    harness.controls.answer = () => Promise.reject("clone exploded")

    await harness.machines.create(request)
    await harness.machines.settled()

    expect((await harness.machines.list())[0]?.error).toBe("clone exploded")
  })
})
