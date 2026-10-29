import { describe, expect, it } from "vitest"

import { HttpFailure, run } from "../server-context.js"
import {
  laptop,
  request,
  startTwoMachines,
  states,
  studio,
  syncRecords,
  type Fleet
} from "./sandbox-manager-test-support.js"
import { JOINED_DEVICE, sandboxHarness } from "./sandbox-test-support.js"

const readyOnLaptop = async (): Promise<Fleet> => {
  const fleet = await startTwoMachines()
  await fleet.laptop.harness.machines.create(request)
  await fleet.laptop.harness.machines.settled()
  return fleet
}

const failure = async (work: Promise<unknown>): Promise<{ status: number; message: string }> => {
  try {
    await work
  } catch (cause) {
    if (cause instanceof HttpFailure) return { status: cause.status, message: cause.message }
    throw cause
  }
  throw new Error("Expected a failure")
}

const archiveRemoteWorkspace = (fleet: Fleet): void => {
  const [workspace] = fleet.laptop.harness.workspaces
  if (workspace === undefined) throw new Error("No workspace was placed")
  fleet.laptop.harness.workspaces[0] = { ...workspace, name: "Renamed box", isArchived: true }
}

const placeholderOn = async (fleet: Fleet) =>
  (await run(fleet.laptop.harness.services.db.listWorkspaces)).find(
    (workspace) => workspace.id === "id-2"
  )

describe("sandboxes managed account-wide", () => {
  it("sends a destroy to the sandbox-manager holder, which tears it down, and both machines forget it", async () => {
    const fleet = await readyOnLaptop()

    await fleet.laptop.harness.machines.destroy("id-1")

    expect(fleet.laptop.harness.removed).toEqual([])
    expect(fleet.studio.harness.removed).toEqual([JOINED_DEVICE])
    expect(fleet.laptop.harness.provider.machines.size).toBe(0)
    expect(await fleet.laptop.harness.machines.list()).toEqual([])
    expect(await fleet.studio.harness.machines.list()).toEqual([])
    expect(fleet.laptop.harness.changes.at(-1)?.[0]).toMatchObject({ key: "id-1", deleted: true })
  })

  it("claims a workspace through the holder and keeps the claim on both machines", async () => {
    const fleet = await startTwoMachines()
    await fleet.laptop.harness.machines.create({ ...request, defersWorkspace: true })
    await fleet.laptop.harness.machines.settled()

    const claimed = await fleet.laptop.harness.machines.claimWorkspace("id-1", "CLAIMED-WS")

    expect(claimed).toMatchObject({ id: "id-1", workspaceId: "claimed-ws" })
    expect((await fleet.studio.harness.machines.get("id-1")).workspaceId).toBe("claimed-ws")
    expect((await fleet.laptop.harness.machines.get("id-1")).workspaceId).toBe("claimed-ws")
  })

  it("says so when nobody holds the role, and passes the holder's refusal on", async () => {
    const fleet = await readyOnLaptop()
    fleet.holder = undefined

    const unheld = await failure(fleet.laptop.harness.machines.destroy("id-1"))
    fleet.holder = studio.deviceId
    const busy = await failure(
      fleet.laptop.harness.machines.claimWorkspace("id-1", "another-workspace")
    )

    expect(unheld).toEqual({
      status: 503,
      message: "No machine is managing sandboxes right now. Try again in a minute."
    })
    expect(busy).toEqual({ status: 409, message: "Spike box can't move to another workspace" })
  })

  it("refuses an action forwarded to a machine that no longer manages the sandbox", async () => {
    const fleet = await readyOnLaptop()
    await syncRecords(fleet.laptop.harness, fleet.studio.harness)
    fleet.holder = laptop.deviceId

    const refused = await failure(
      fleet.studio.harness.machines.receive({
        request: { action: "destroy", id: "id-1" },
        record: await fleet.laptop.harness.records.entry("id-1")
      })
    )

    expect(refused).toEqual({
      status: 409,
      message: "This machine doesn't manage Spike box right now"
    })
  })

  it("fails a claim when the holder answers without the sandbox", async () => {
    const harness = await sandboxHarness({
      management: {
        held: () => false,
        holder: () => studio.serverId,
        forward: async (_machine, forwarded) => ({ record: forwarded.record })
      }
    })
    await harness.machines.create({ ...request, defersWorkspace: true })
    await harness.machines.settled()

    const failed = await failure(harness.machines.claimWorkspace("id-1", "claimed-ws"))

    expect(failed).toEqual({
      status: 502,
      message: "The sandbox manager didn't return the sandbox"
    })
  })

  it("passes on a teardown that failed on the holder", async () => {
    const fleet = await readyOnLaptop()
    fleet.studio.harness.controls.removeFails = true

    const failed = await failure(fleet.laptop.harness.machines.destroy("id-1"))

    expect(failed).toEqual({ status: 500, message: "cloud unreachable" })
  })

  it("says the machine can't be reached when forwarding fails before an answer", async () => {
    const fleet = await readyOnLaptop()
    fleet.holder = "device-gone"

    const unreachable = await failure(fleet.laptop.harness.machines.destroy("id-1"))

    expect(unreachable).toEqual({ status: 503, message: "No machine cloud:device-gone" })
  })

  it("watches cloud sandboxes only on the holder, which picks them up once the records sync", async () => {
    const fleet = await readyOnLaptop()
    fleet.laptop.harness.provider.machines.clear()

    await fleet.laptop.harness.machines.watch()
    const beforeSync = await states(fleet.laptop.harness)
    await syncRecords(fleet.laptop.harness, fleet.studio.harness)
    await fleet.studio.harness.machines.watch()

    expect(beforeSync).toEqual([{ id: "id-1", state: "ready" }])
    expect(fleet.studio.harness.logs).toContain(
      "Destroying sandbox Spike box (id-1): its e2b machine ended"
    )
    expect(await fleet.studio.harness.machines.list()).toEqual([])
  })

  it("leaves host-local sandboxes to the machine that runs them, even when another machine holds the role", async () => {
    const fleet = await readyOnLaptop()
    fleet.hostLocal = true
    await syncRecords(fleet.laptop.harness, fleet.studio.harness)
    fleet.laptop.harness.provider.machines.clear()

    await fleet.studio.harness.machines.watch()
    const onHolder = await states(fleet.studio.harness)
    await fleet.studio.harness.machines.destroy("id-1")

    expect(onHolder).toEqual([{ id: "id-1", state: "ready" }])
    expect(fleet.laptop.harness.removed).toEqual([JOINED_DEVICE])
    expect(await fleet.studio.harness.machines.list()).toEqual([])
  })

  it("never fails or retires setup that another machine is running", async () => {
    const fleet = await startTwoMachines()
    await fleet.laptop.harness.records.put({
      id: "elsewhere",
      name: "Elsewhere",
      projectId: "project-1",
      provider: "e2b",
      accountId: "account-1",
      state: "bootstrapping",
      createdAt: "2026-10-23T00:00:00.000Z",
      createdOn: laptop.serverId
    })
    await syncRecords(fleet.laptop.harness, fleet.studio.harness)

    await fleet.studio.harness.machines.sweep()
    await fleet.studio.harness.machines.retireProvider("account-1")

    expect(await states(fleet.studio.harness)).toEqual([
      { id: "elsewhere", state: "bootstrapping" }
    ])
  })

  it("hands an archived workspace's placeholder back to the machine that made the sandbox", async () => {
    const fleet = await readyOnLaptop()
    archiveRemoteWorkspace(fleet)
    await syncRecords(fleet.laptop.harness, fleet.studio.harness)

    await fleet.studio.harness.machines.watch()
    const handedBack = await fleet.studio.harness.machines.get("id-1")
    await syncRecords(fleet.studio.harness, fleet.laptop.harness)
    await fleet.laptop.harness.machines.watch()

    expect(handedBack).toMatchObject({
      state: "archived",
      createdOn: laptop.serverId,
      placeholderPending: true
    })
    expect(await fleet.laptop.harness.machines.get("id-1")).not.toHaveProperty("placeholderPending")
    expect(await placeholderOn(fleet)).toMatchObject({ isArchived: true, name: "Renamed box" })
  })

  it("keeps only the placeholder when the holder retires a sandbox whose provider was deleted", async () => {
    const fleet = await readyOnLaptop()
    await syncRecords(fleet.laptop.harness, fleet.studio.harness)

    await fleet.studio.harness.machines.retireProvider("account-1")
    await syncRecords(fleet.studio.harness, fleet.laptop.harness)
    await fleet.laptop.harness.machines.watch()

    expect(fleet.studio.harness.removed).toEqual([JOINED_DEVICE])
    expect(await fleet.laptop.harness.machines.list()).toEqual([])
    expect(await placeholderOn(fleet)).toMatchObject({ isArchived: true, name: "Spike box" })
  })
})
