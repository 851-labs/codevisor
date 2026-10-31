import { machineField } from "@codevisor/sandboxes"
import { describe, expect, it } from "vitest"

import { HttpFailure, run } from "../server-context.js"
import {
  FAKE_PROFILE,
  JOINED_DEVICE,
  JOINED_SERVER,
  OWNER,
  sandboxHarness
} from "./sandbox-test-support.js"

const request = { profileId: "profile-1", projectId: "project-1", name: "Spike box" }

const archived = async () => {
  const harness = await ready()
  const workspace = harness.workspaces[0]
  if (workspace === undefined) throw new Error("No workspace was placed")
  harness.workspaces[0] = { ...workspace, name: "Renamed box", isArchived: true }
  await harness.machines.watch()
  return harness
}

const placeholder = async (harness: Awaited<ReturnType<typeof ready>>) =>
  (await run(harness.services.db.listWorkspaces)).find((workspace) => workspace.id === "id-2")

const ready = async () => {
  const harness = await sandboxHarness()
  await harness.machines.create(request)
  await harness.machines.settled()
  return harness
}

describe("creating a sandbox", () => {
  it("creates, bootstraps with a sandbox invite, joins, syncs one way, clones and places a labeled workspace", async () => {
    const harness = await sandboxHarness()

    const started = await harness.machines.create(request)
    await harness.machines.settled()

    expect(started.state).toBe("creating")
    expect(await harness.machines.list()).toEqual([
      {
        id: "id-1",
        name: "Spike box",
        projectId: "project-1",
        provider: "e2b",
        profileId: "profile-1",
        profileName: "Ubuntu Sandbox",
        accountId: "account-1",
        state: "ready",
        createdAt: "2026-10-23T00:00:00.000Z",
        createdOn: "server-owner",
        providerMachineId: "fake-1",
        platform: "linux",
        deviceId: JOINED_DEVICE,
        machineId: JOINED_SERVER,
        remoteProjectId: "remote-project",
        workspaceId: "id-2",
        workspaceOpenedAt: "2026-10-23T00:00:00.000Z",
        plan: ["create", "install", "signIn", "sync", "clone"],
        steps: ["create", "install", "signIn", "sync", "clone"].map((stage) => ({
          stage,
          startedAt: "2026-10-23T00:00:00.000Z",
          endedAt: "2026-10-23T00:00:00.000Z"
        }))
      }
    ])
    expect(harness.provider.machines.get("fake-1")?.spec.tags).toEqual({
      owner: OWNER,
      machine: "id-1"
    })
    expect(harness.provider.execs[0]?.request.stdin).toBe("cvi1.aW52aXRl.e2b-secret-invite-token\n")
    expect(harness.toolCalls.map((call) => [call.machineId, call.tool])).toEqual([
      [JOINED_SERVER, "codevisor.projects.clone"],
      [JOINED_SERVER, "codevisor.workspaces.upsert"]
    ])
    expect(harness.toolCalls[1]?.args).toMatchObject({
      workspaceId: "id-2",
      projectId: "remote-project",
      labels: { "codevisor-sandbox": "id-1" }
    })
  })

  it("starts a scratch project when the project has no remote", async () => {
    const harness = await sandboxHarness({ project: { repoUrl: undefined } })

    await harness.machines.create(request)
    await harness.machines.settled()

    expect(harness.toolCalls[0]?.tool).toBe("codevisor.projects.create_scratch")
    expect((await harness.machines.list())[0]?.remoteProjectId).toBe("remote-scratch")
  })

  it("names the sandbox after its profile when no name is given", async () => {
    const harness = await sandboxHarness()

    const started = await harness.machines.create({
      profileId: "profile-1",
      projectId: "project-1"
    })
    await harness.machines.settled()

    expect(started.name).toBe("Ubuntu Sandbox id-1")
  })

  it("starts with the profile's options as they are when the sandbox starts", async () => {
    const harness = await sandboxHarness()

    await harness.machines.create(request)
    await harness.settings.putProfile({ ...FAKE_PROFILE, values: { size: "large" } })
    await harness.machines.create(request)
    await harness.machines.settled()

    expect([...harness.provider.machines.values()].map((machine) => machine.options)).toEqual([
      { size: "small" },
      { size: "large" }
    ])
  })

  it("rejects a missing profile, invalid profile options and a profile for another Mac", async () => {
    const harness = await sandboxHarness({
      extraProfileFields: [machineField("machineId", "Mac", "tart")]
    })
    await harness.settings.putProfile({ ...FAKE_PROFILE, id: "bad", values: { size: 7 } })
    await harness.settings.putProfile({
      ...FAKE_PROFILE,
      id: "elsewhere",
      name: "Studio VM",
      values: { machineId: "server-studio" }
    })

    const failures = await Promise.all(
      ["missing", "bad", "elsewhere"].map((profileId) =>
        harness.machines.create({ ...request, profileId }).catch((cause: unknown) => cause)
      )
    )

    expect(failures).toEqual([
      new HttpFailure(404, "No sandbox profile missing"),
      new HttpFailure(400, "Size must be text"),
      new HttpFailure(409, "Studio VM runs on another Mac")
    ])
    expect(harness.provider.machines.size).toBe(0)
  })

  it("refuses to start before this machine is on an account", async () => {
    const harness = await sandboxHarness({ owner: undefined })

    await expect(harness.machines.create(request)).rejects.toThrow(
      "Connect this machine to your Codevisor account first"
    )
  })

  it("tears down a machine whose install fails and keeps the error", async () => {
    const harness = await sandboxHarness({ bootstrapExit: 1 })

    await harness.machines.create(request)
    await harness.machines.settled()

    const [failed] = await harness.machines.list()
    expect(failed?.state).toBe("failed")
    expect(failed?.error).toContain("failed (exit 1):\ninstall failed")
    expect(harness.provider.machines.size).toBe(0)
    expect(harness.removed).toEqual([])
  })

  it("tears down when the machine never shows up on the account", async () => {
    const harness = await sandboxHarness({ joins: false })

    await harness.machines.create(request)
    await harness.machines.settled()

    expect((await harness.machines.list())[0]).toMatchObject({
      state: "failed",
      error: "Codevisor was installed, but the machine never came online on the account"
    })
    expect(harness.provider.machines.size).toBe(0)
  })

  it("removes the joined machine from the account when a later step fails", async () => {
    const harness = await sandboxHarness({ project: { id: "elsewhere" } })

    await harness.machines.create(request)
    await harness.machines.settled()

    expect((await harness.machines.list())[0]).toMatchObject({
      state: "failed",
      error: "No project project-1 on this machine"
    })
    expect(harness.removed).toEqual([JOINED_DEVICE])
    expect(harness.provider.machines.size).toBe(0)
  })
})

describe("sandbox lifetime", () => {
  it("destroys on request: off the account first, then the provider machine, then the record", async () => {
    const harness = await ready()

    await harness.machines.destroy("id-1")

    expect(harness.removed).toEqual([JOINED_DEVICE])
    expect(harness.provider.machines.size).toBe(0)
    expect(await harness.machines.list()).toEqual([])

    const unreachable = await ready()
    unreachable.controls.removeFails = true
    await expect(unreachable.machines.destroy("id-1")).rejects.toThrow("cloud unreachable")
    expect(unreachable.provider.machines.size).toBe(1)
  })

  it("answers 404 for an unknown machine and 409 while it's being torn down", async () => {
    const harness = await ready()
    await expect(harness.machines.destroy("nope")).rejects.toMatchObject({ status: 404 })

    const first = harness.machines.destroy("id-1")

    await expect(harness.machines.destroy("id-1")).rejects.toMatchObject({ status: 409 })
    await first
  })

  it("stops setting up a machine that is destroyed before it's ready, and removes it", async () => {
    const harness = await sandboxHarness()
    await harness.machines.create(request)

    await harness.machines.destroy("id-1")
    await harness.machines.settled()

    expect(harness.provider.machines.size).toBe(0)
    expect(harness.removed).toEqual([])
    expect(await harness.machines.list()).toEqual([])
    expect(harness.logs).toContain("Destroying sandbox Spike box (id-1): nobody used it")
  })

  it("tears down a machine destroyed during its last setup step, once that step ends", async () => {
    const harness = await sandboxHarness()
    let destroyed: Promise<void> | undefined
    harness.controls.answer = () => {
      destroyed ??= harness.machines.destroy("id-1")
      return undefined
    }
    await harness.machines.create(request)
    await harness.machines.settled()
    await destroyed

    expect(harness.removed).toEqual([JOINED_DEVICE])
    expect(harness.provider.machines.size).toBe(0)
    expect(await harness.machines.list()).toEqual([])
  })

  it("tears the sandbox down when its workspace is archived, keeping an archived workspace here to restore", async () => {
    const harness = await archived()

    expect(harness.logs).toContain(
      "Destroying sandbox Spike box (id-1): its workspace was archived"
    )
    expect(harness.removed).toEqual([JOINED_DEVICE])
    expect(harness.provider.machines.size).toBe(0)
    expect(await harness.machines.list()).toEqual([
      {
        id: "id-1",
        name: "Spike box",
        projectId: "project-1",
        provider: "e2b",
        profileId: "profile-1",
        profileName: "Ubuntu Sandbox",
        accountId: "account-1",
        state: "archived",
        createdAt: "2026-10-23T00:00:00.000Z",
        createdOn: "server-owner",
        workspaceId: "id-2",
        workspaceName: "Renamed box"
      }
    ])
    expect(await placeholder(harness)).toMatchObject({
      isArchived: true,
      name: "Renamed box",
      labels: { "codevisor-sandbox-restore": "id-1" }
    })
    expect(harness.events).toEqual(["workspace.updated id-2"])
  })

  it("starts a new sandbox from the same profile when the archived workspace is restored", async () => {
    const harness = await archived()

    await harness.machines.restore("ID-2")
    await harness.machines.settled()

    expect(await harness.machines.list()).toMatchObject([
      {
        id: "id-3",
        state: "ready",
        profileId: "profile-1",
        workspaceId: "id-2",
        restoresWorkspace: true
      }
    ])
    expect(harness.toolCalls.at(-1)).toMatchObject({
      tool: "codevisor.workspaces.upsert",
      args: { workspaceId: "id-2", name: "Renamed box" }
    })
    expect(await placeholder(harness)).toBeUndefined()
    expect(harness.events).toEqual(["workspace.updated id-2", "workspace.deleted id-2"])
    expect(harness.provider.machines.size).toBe(1)
  })

  it("restores nothing for a workspace no archived sandbox owns", async () => {
    const harness = await ready()

    await harness.machines.restore("id-2")
    await harness.machines.restore("unknown")

    expect((await harness.machines.list()).map((machine) => machine.state)).toEqual(["ready"])
  })

  it("tears down when the workspace is gone or the provider machine ended", async () => {
    const deleted = await ready()
    deleted.workspaces.splice(0)
    await deleted.machines.watch()
    expect(await deleted.machines.list()).toEqual([])

    const expired = await ready()
    const machine = expired.provider.machines.get("fake-1")
    if (machine !== undefined) machine.state = "stopped"
    await expired.machines.watch()
    expect(expired.removed).toEqual([JOINED_DEVICE])
    expect(await expired.machines.list()).toEqual([])
  })

  it("resumes a stopped machine that can be resumed and restarts its server", async () => {
    const harness = await sandboxHarness({ resumable: true })
    await harness.machines.create(request)
    await harness.machines.settled()
    const machine = harness.provider.machines.get("fake-1")
    if (machine !== undefined) machine.state = "stopped"

    await harness.machines.watch()

    expect(harness.logs).toContain("Resuming sandbox Spike box (id-1)")
    expect(await harness.provider.status("fake-1")).toEqual({ state: "running" })
    expect(harness.provider.execs.at(-1)?.request.script).toContain('codevisor" start')
    expect((await harness.machines.list())[0]?.state).toBe("ready")
  })

  it("keeps the machine when the sandbox can't be reached", async () => {
    const harness = await ready()
    harness.controls.offline = true

    await harness.machines.watch()

    expect((await harness.machines.list())[0]?.state).toBe("ready")
  })
})

describe("sweeping orphans", () => {
  it("destroys provider machines this owner has no live record for", async () => {
    const harness = await sandboxHarness()
    await harness.provider.create(
      { name: "orphan", tags: { owner: OWNER, machine: "lost" } },
      { size: "small" }
    )
    await harness.provider.create(
      { name: "other", tags: { owner: "someone-else", machine: "x" } },
      { size: "small" }
    )

    await harness.machines.sweep()

    expect([...harness.provider.machines.values()].map((machine) => machine.spec.name)).toEqual([
      "other"
    ])
    expect(harness.logs).toEqual(["Destroying orphaned Fake sandbox fake-1"])
  })

  it("fails and tears down records a restart interrupted, and leaves ready ones alone", async () => {
    const harness = await sandboxHarness()
    await harness.machines.create(request)
    await harness.machines.settled()
    const created = await harness.provider.create(
      { name: "half", tags: { owner: OWNER, machine: "half" } },
      { size: "small" }
    )
    await harness.records.put({
      id: "half",
      provider: "e2b",
      accountId: "account-1",
      name: "half",
      projectId: "project-1",
      state: "bootstrapping",
      createdAt: "2026-10-23T00:00:00.000Z",
      providerMachineId: created.providerMachineId
    })

    await harness.machines.sweep()

    const byId = new Map((await harness.machines.list()).map((machine) => [machine.id, machine]))
    expect(byId.get("half")).toMatchObject({
      state: "failed",
      error: "Interrupted by a server restart"
    })
    expect(byId.get("id-1")?.state).toBe("ready")
    expect([...harness.provider.machines.keys()]).toEqual(["fake-1"])
  })

  it("does nothing before the owner is known and logs a provider that can't list", async () => {
    const unowned = await sandboxHarness({ owner: undefined })
    await unowned.provider.create(
      { name: "orphan", tags: { owner: OWNER, machine: "lost" } },
      { size: "small" }
    )
    await unowned.machines.sweep()
    expect(unowned.provider.machines.size).toBe(1)

    const broken = await sandboxHarness()
    broken.controls.listFails = true
    await broken.machines.sweep()
    expect(broken.logs).toEqual(["Sandbox sweep of e2b failed: 401 from provider"])
  })
})

describe("edges of the pipeline", () => {
  it("records a provider that can't create a machine without touching the account", async () => {
    const harness = await sandboxHarness()
    harness.controls.createFails = true

    await harness.machines.create(request)
    await harness.machines.settled()

    expect((await harness.machines.list())[0]).toMatchObject({
      state: "failed",
      error: "quota exceeded"
    })
    expect(harness.removed).toEqual([])
  })

  it("addresses a joined machine without a server id by its cloud device id", async () => {
    const harness = await sandboxHarness({ joinWithoutServerId: true })

    await harness.machines.create(request)
    await harness.machines.settled()

    expect((await harness.machines.list())[0]?.machineId).toBe(`cloud:${JOINED_DEVICE}`)
  })

  it("carries the project's worktree base and run location into the clone", async () => {
    const harness = await sandboxHarness({
      project: {
        worktreeBase: { remote: "origin", branch: "main" },
        defaultRunLocation: "newWorktree"
      }
    })

    await harness.machines.create(request)
    await harness.machines.settled()

    expect(harness.toolCalls[0]?.args).toEqual({
      url: "https://github.com/851-labs/codevisor.git",
      name: "codevisor",
      worktreeBase: { remote: "origin", branch: "main" },
      defaultRunLocation: "newWorktree"
    })
  })

  it("fails when the clone answers without a project id", async () => {
    const harness = await sandboxHarness()
    harness.controls.answer = (tool) =>
      tool === "codevisor.projects.clone" ? { ok: true } : undefined

    await harness.machines.create(request)
    await harness.machines.settled()

    expect((await harness.machines.list())[0]?.error).toBe("The sandbox didn't return a project id")
  })

  it("keeps a machine whose workspace list comes back malformed", async () => {
    const harness = await sandboxHarness()
    await harness.machines.create(request)
    await harness.machines.settled()
    harness.controls.answer = () => ({ unexpected: true })

    await harness.machines.watch()

    expect((await harness.machines.list())[0]?.state).toBe("ready")
  })
})
