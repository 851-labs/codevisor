import type { Sandbox } from "@codevisor/api"
import { describe, expect, it, vi } from "vitest"

import { run } from "../server-context.js"
import { FAKE_ACCOUNT, JOINED_DEVICE, sandboxHarness } from "./sandbox-test-support.js"

const request = { profileId: "profile-1", projectId: "project-1", name: "Spike box" }

type Harness = Awaited<ReturnType<typeof sandboxHarness>>

const placed = async () => {
  const harness = await sandboxHarness()
  await harness.machines.create(request)
  await harness.machines.settled()
  return harness
}

const record = (overrides: Partial<Sandbox>): Sandbox => ({
  id: "other",
  name: "other",
  projectId: "project-1",
  provider: "e2b",
  accountId: "account-1",
  state: "ready",
  createdAt: "2026-10-23T00:00:00.000Z",
  ...overrides
})

const archivedWorkspaces = async (harness: Harness) =>
  (await run(harness.services.db.listWorkspaces))
    .filter((workspace) => workspace.isArchived)
    .map((workspace) => ({ id: workspace.id, name: workspace.name }))

const renameRemoteWorkspace = (harness: Harness, name: string): void => {
  const [workspace] = harness.workspaces
  if (workspace !== undefined) harness.workspaces[0] = { ...workspace, name }
}

describe("retiring a provider's sandboxes", () => {
  it("archives each workspace under its current name, destroys its machine and forgets failures", async () => {
    const harness = await placed()
    renameRemoteWorkspace(harness, "Renamed")
    await harness.records.put(record({ id: "broken", state: "failed" }))
    await harness.records.put(record({ id: "elsewhere", accountId: "account-2" }))

    await harness.machines.retireProvider("account-1")

    expect(harness.removed).toEqual([JOINED_DEVICE])
    expect(harness.provider.machines.size).toBe(0)
    expect(await archivedWorkspaces(harness)).toEqual([{ id: "id-2", name: "Renamed" }])
    expect((await harness.machines.list()).map((machine) => machine.id)).toEqual(["elsewhere"])
  })

  it("names the archived workspace after the sandbox when its machine can't be asked", async () => {
    const harness = await placed()
    harness.controls.offline = true

    await harness.machines.retireProvider("account-1")

    expect(await archivedWorkspaces(harness)).toEqual([{ id: "id-2", name: "Spike box" }])
  })

  it("falls back to the sandbox's own names when its machine doesn't list the workspace or its name", async () => {
    const harness = await sandboxHarness()
    harness.workspaces.push({ id: "named-nothing", isArchived: false })
    await harness.records.put(record({ id: "a", workspaceId: "kept", workspaceName: "Kept" }))
    await harness.records.put(record({ id: "b", workspaceId: "gone", machineId: "m" }))
    await harness.records.put(record({ id: "c", workspaceId: "named-nothing", machineId: "m" }))

    await harness.machines.retireProvider("account-1")

    expect(await archivedWorkspaces(harness)).toEqual(
      expect.arrayContaining([
        { id: "kept", name: "Kept" },
        { id: "gone", name: "other" },
        { id: "named-nothing", name: "other" }
      ])
    )
  })

  it("tears down a sandbox that never got a workspace and stops one still setting up", async () => {
    const harness = await sandboxHarness()
    const listing = Promise.withResolvers<void>()
    const answer = Promise.withResolvers<void>()
    harness.controls.answer = (tool) => {
      listing.resolve()
      return answer.promise.then(() => ({ id: `${tool}-result` }))
    }
    await harness.records.put(record({ id: "bare", workspaceName: "Old name" }))

    const setup = await harness.machines.create(request)
    await listing.promise
    await harness.machines.retireProvider("account-1")
    answer.resolve()
    await harness.machines.settled()

    expect(harness.logs).toContain(`Destroying sandbox Spike box (${setup.id}): nobody used it`)
    expect(await harness.machines.list()).toEqual([])
  })
})

describe("a provider deleted on another Mac", () => {
  it("lets the next check archive this Mac's sandboxes with the credentials it kept", async () => {
    const harness = await placed()
    await harness.machines.watch()

    await harness.settings.removeAccount("account-1")
    await harness.machines.watch()

    expect(harness.provider.machines.size).toBe(0)
    expect(await archivedWorkspaces(harness)).toEqual([{ id: "id-2", name: "Spike box" }])
    expect(await harness.machines.list()).toEqual([])
  })

  it("keeps trying while it still has the credentials", async () => {
    const harness = await placed()
    await harness.machines.watch()
    harness.controls.removeFails = true

    await harness.settings.removeAccount("account-1")
    await harness.machines.watch()

    expect(harness.logs).toContain(
      "Tearing down sandbox Spike box (id-1) failed: cloud unreachable"
    )
    expect((await harness.machines.list())[0]?.state).toBe("destroying")
  })

  it("logs what went wrong when the vendor throws something that isn't an Error", async () => {
    const harness = await placed()
    await harness.machines.watch()
    vi.spyOn(harness.provider, "destroy").mockRejectedValue("vendor down")

    await harness.settings.removeAccount("account-1")
    await harness.machines.watch()

    expect(harness.logs).toContain("Tearing down sandbox Spike box (id-1) failed: vendor down")
  })

  it("says which vendor machine to delete by hand when the credentials are gone", async () => {
    const harness = await sandboxHarness()
    await harness.records.put(record({ providerMachineId: "fake-9" }))
    await harness.records.put(record({ id: "unlinked", accountId: undefined }))

    await harness.settings.removeAccount("account-1")
    await harness.machines.watch()

    expect(await harness.machines.list()).toMatchObject([
      {
        id: "other",
        state: "failed",
        error:
          "Its e2b provider was deleted before this Mac could tear it down. Delete fake-9 in your e2b account."
      },
      { id: "unlinked", state: "ready" }
    ])
  })

  it("names the machine generically when it never reached the vendor", async () => {
    const harness = await sandboxHarness()
    await harness.records.put(record({ id: "early", accountId: "gone", state: "destroying" }))

    await harness.machines.watch()

    expect((await harness.machines.list())[0]?.error).toBe(
      "Its e2b provider was deleted before this Mac could tear it down. Delete its machine in your e2b account."
    )
  })
})

describe("kept provider credentials", () => {
  it("keeps only the providers this Mac's sandboxes use", async () => {
    const harness = await placed()
    await harness.settings.putAccount({ ...FAKE_ACCOUNT, id: "spare" })
    await harness.machines.watch()
    await harness.settings.removeAccount("account-1")
    await harness.settings.removeAccount("spare")

    expect(await harness.deps.providerAccounts.account("account-1")).toMatchObject({
      values: { apiKey: "e2b_secret" }
    })
    expect(await harness.deps.providerAccounts.account("spare")).toBeUndefined()
  })
})
