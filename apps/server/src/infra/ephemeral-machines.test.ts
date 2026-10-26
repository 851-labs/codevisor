import { describe, expect, it } from "vitest"

import { HttpFailure } from "../server-context.js"
import { configuredProviderIds } from "./ephemeral-machines.js"
import { ephemeralHarness, JOINED_DEVICE, JOINED_SERVER, OWNER } from "./ephemeral-test-support.js"

const request = { provider: "e2b" as const, projectId: "project-1", name: "Spike box" }

const ready = async () => {
  const harness = await ephemeralHarness()
  await harness.machines.create(request)
  await harness.machines.settled()
  return harness
}

describe("creating an ephemeral machine", () => {
  it("creates, bootstraps with an ephemeral invite, joins, syncs one way, clones and places a labeled workspace", async () => {
    const harness = await ephemeralHarness()

    const started = await harness.machines.create(request)
    await harness.machines.settled()

    expect(started.state).toBe("creating")
    expect(await harness.machines.list()).toEqual([
      {
        id: "id-1",
        provider: "e2b",
        name: "Spike box",
        projectId: "project-1",
        state: "ready",
        createdAt: "2026-10-23T00:00:00.000Z",
        providerMachineId: "fake-1",
        platform: "linux",
        deviceId: JOINED_DEVICE,
        machineId: JOINED_SERVER,
        remoteProjectId: "remote-project",
        workspaceId: "id-2",
        workspaceOpenedAt: "2026-10-23T00:00:00.000Z"
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
      labels: { "codevisor-ephemeral": "id-1" }
    })
  })

  it("starts a scratch project when the project has no remote", async () => {
    const harness = await ephemeralHarness({ project: { repoUrl: undefined } })

    await harness.machines.create(request)
    await harness.machines.settled()

    expect(harness.toolCalls[0]?.tool).toBe("codevisor.projects.create_scratch")
    expect((await harness.machines.list())[0]?.remoteProjectId).toBe("remote-scratch")
  })

  it("names the machine after the provider when no name is given", async () => {
    const harness = await ephemeralHarness()

    const started = await harness.machines.create({ provider: "e2b", projectId: "project-1" })
    await harness.machines.settled()

    expect(started.name).toBe("Fake id-1")
  })

  it("applies per-project provider options under request overrides", async () => {
    const harness = await ephemeralHarness()
    await harness.records.setProjectOptions("project-1", { e2b: { size: "large" } })

    await harness.machines.create(request)
    await harness.machines.create({ ...request, options: { size: "huge" } })
    await harness.machines.settled()

    expect([...harness.provider.machines.values()].map((machine) => machine.options)).toEqual([
      { size: "large" },
      { size: "huge" }
    ])
  })

  it("rejects invalid options as a bad request before creating anything", async () => {
    const harness = await ephemeralHarness()

    const failure = await harness.machines
      .create({ ...request, options: { size: 7 } })
      .catch((cause: unknown) => cause)

    expect(failure).toBeInstanceOf(HttpFailure)
    expect(failure).toMatchObject({ status: 400 })
    expect(harness.provider.machines.size).toBe(0)
  })

  it("refuses to start before this machine is on an account", async () => {
    const harness = await ephemeralHarness({ owner: undefined })

    await expect(harness.machines.create(request)).rejects.toThrow(
      "Connect this machine to your Codevisor account first"
    )
  })

  it("tears down a machine whose install fails and keeps the error", async () => {
    const harness = await ephemeralHarness({ bootstrapExit: 1 })

    await harness.machines.create(request)
    await harness.machines.settled()

    const [failed] = await harness.machines.list()
    expect(failed?.state).toBe("failed")
    expect(failed?.error).toContain("failed (exit 1):\ninstall failed")
    expect(harness.provider.machines.size).toBe(0)
    expect(harness.removed).toEqual([])
  })

  it("tears down when the machine never shows up on the account", async () => {
    const harness = await ephemeralHarness({ joins: false })

    await harness.machines.create(request)
    await harness.machines.settled()

    expect((await harness.machines.list())[0]).toMatchObject({
      state: "failed",
      error: "Codevisor was installed, but the machine never came online on the account"
    })
    expect(harness.provider.machines.size).toBe(0)
  })

  it("removes the joined machine from the account when a later step fails", async () => {
    const harness = await ephemeralHarness({ project: { id: "elsewhere" } })

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

describe("ephemeral machine lifetime", () => {
  it("destroys on request: off the account first, then the provider machine, then the record", async () => {
    const harness = await ready()

    await harness.machines.destroy("id-1")

    expect(harness.removed).toEqual([JOINED_DEVICE])
    expect(harness.provider.machines.size).toBe(0)
    expect(await harness.machines.list()).toEqual([])
  })

  it("answers 404 for an unknown machine and 409 while it's still being set up", async () => {
    const harness = await ephemeralHarness()
    await expect(harness.machines.destroy("nope")).rejects.toMatchObject({ status: 404 })

    await harness.machines.create(request)

    await expect(harness.machines.destroy("id-1")).rejects.toMatchObject({ status: 409 })
    await harness.machines.settled()
  })

  it("tears the machine down once its workspace is archived on the ephemeral machine", async () => {
    const harness = await ready()
    await harness.machines.watch()
    expect(harness.provider.machines.size).toBe(1)

    const workspace = harness.workspaces[0]
    if (workspace !== undefined) workspace.isArchived = true
    await harness.machines.watch()

    expect(harness.logs).toContain(
      "Destroying ephemeral machine Spike box (id-1): its workspace was archived"
    )
    expect(harness.removed).toEqual([JOINED_DEVICE])
    expect(harness.provider.machines.size).toBe(0)
    expect(await harness.machines.list()).toEqual([])
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
    const harness = await ephemeralHarness({ resumable: true })
    await harness.machines.create(request)
    await harness.machines.settled()
    const machine = harness.provider.machines.get("fake-1")
    if (machine !== undefined) machine.state = "stopped"

    await harness.machines.watch()

    expect(harness.logs).toContain("Resuming ephemeral machine Spike box (id-1)")
    expect(await harness.provider.status("fake-1")).toEqual({ state: "running" })
    expect(harness.provider.execs.at(-1)?.request.script).toContain('codevisor" start')
    expect((await harness.machines.list())[0]?.state).toBe("ready")
  })

  it("keeps the machine when the ephemeral machine can't be reached", async () => {
    const harness = await ready()
    harness.controls.offline = true

    await harness.machines.watch()

    expect((await harness.machines.list())[0]?.state).toBe("ready")
  })
})

describe("sweeping orphans", () => {
  it("destroys provider machines this owner has no live record for", async () => {
    const harness = await ephemeralHarness()
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
    expect(harness.logs).toEqual(["Destroying orphaned Fake machine fake-1"])
  })

  it("fails and tears down records a restart interrupted, and leaves ready ones alone", async () => {
    const harness = await ephemeralHarness()
    await harness.machines.create(request)
    await harness.machines.settled()
    const created = await harness.provider.create(
      { name: "half", tags: { owner: OWNER, machine: "half" } },
      { size: "small" }
    )
    await harness.records.put({
      id: "half",
      provider: "e2b",
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
    const unowned = await ephemeralHarness({ owner: undefined })
    await unowned.provider.create(
      { name: "orphan", tags: { owner: OWNER, machine: "lost" } },
      { size: "small" }
    )
    await unowned.machines.sweep()
    expect(unowned.provider.machines.size).toBe(1)

    const broken = await ephemeralHarness()
    broken.controls.listFails = true
    await broken.machines.sweep()
    expect(broken.logs).toEqual(["Ephemeral sweep of e2b failed: 401 from provider"])
  })
})

describe("edges of the pipeline", () => {
  it("records a provider that can't create a machine without touching the account", async () => {
    const harness = await ephemeralHarness()
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
    const harness = await ephemeralHarness({ joinWithoutServerId: true })

    await harness.machines.create(request)
    await harness.machines.settled()

    expect((await harness.machines.list())[0]?.machineId).toBe(`cloud:${JOINED_DEVICE}`)
  })

  it("carries the project's worktree base and run location into the clone", async () => {
    const harness = await ephemeralHarness({
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
    const harness = await ephemeralHarness()
    harness.controls.answer = (tool) =>
      tool === "codevisor.projects.clone" ? { ok: true } : undefined

    await harness.machines.create(request)
    await harness.machines.settled()

    expect((await harness.machines.list())[0]?.error).toBe(
      "The ephemeral machine didn't return a project id"
    )
  })

  it("keeps a machine whose workspace list comes back malformed", async () => {
    const harness = await ephemeralHarness()
    await harness.machines.create(request)
    await harness.machines.settled()
    harness.controls.answer = () => ({ unexpected: true })

    await harness.machines.watch()

    expect((await harness.machines.list())[0]?.state).toBe("ready")
  })

  it("lists only providers that have credentials", async () => {
    const configured = await configuredProviderIds((id) => Promise.resolve(id !== "modal"))

    expect(configured).toEqual(["e2b", "tart"])
  })
})

describe("teardown robustness", () => {
  it("runs one teardown when two watch ticks overlap", async () => {
    const harness = await ready()
    harness.workspaces.splice(0)

    await Promise.all([harness.machines.watch(), harness.machines.watch()])

    expect(harness.removed).toEqual([JOINED_DEVICE])
    expect(await harness.machines.list()).toEqual([])
  })

  it("only watches machines that finished setting up", async () => {
    const harness = await ephemeralHarness({ bootstrapExit: 1 })
    await harness.machines.create(request)
    await harness.machines.settled()

    await harness.machines.watch()

    expect(harness.toolCalls).toEqual([])
    expect((await harness.machines.list())[0]?.state).toBe("failed")
  })

  it("still records the failure when tearing down a failed setup fails too", async () => {
    const harness = await ephemeralHarness({ project: { id: "elsewhere" } })
    harness.controls.removeFails = true

    await harness.machines.create(request)
    await harness.machines.settled()

    expect((await harness.machines.list())[0]).toMatchObject({
      state: "failed",
      error: "No project project-1 on this machine"
    })
  })

  it("marks an interrupted record failed even when its teardown can't reach the cloud", async () => {
    const harness = await ephemeralHarness()
    harness.controls.removeFails = true
    await harness.records.put({
      id: "half",
      provider: "e2b",
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
    const harness = await ephemeralHarness()
    harness.controls.answer = () => Promise.reject("clone exploded")

    await harness.machines.create(request)
    await harness.machines.settled()

    expect((await harness.machines.list())[0]?.error).toBe("clone exploded")
  })
})

describe("ephemeral machines on newer servers", () => {
  it("understands normalized tool results: named ids and item lists", async () => {
    const harness = await ephemeralHarness()
    harness.controls.answer = (tool) => {
      if (tool === "codevisor.projects.clone") return { projectId: "remote-normalized" }
      if (tool !== "codevisor.workspaces.list") return undefined
      return {
        items: [
          "noise",
          ...harness.workspaces.map(({ id, isArchived }) => ({ workspaceId: id, isArchived }))
        ]
      }
    }

    await harness.machines.create(request)
    await harness.machines.settled()
    await harness.machines.watch()

    expect((await harness.machines.list())[0]).toMatchObject({
      state: "ready",
      remoteProjectId: "remote-normalized"
    })

    const workspace = harness.workspaces[0]
    if (workspace !== undefined) workspace.isArchived = true
    await harness.machines.watch()

    expect(await harness.machines.list()).toEqual([])
  })
})
