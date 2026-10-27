import { describe, expect, it } from "vitest"

import { sandboxHarness } from "./sandbox-test-support.js"

const clientWorkspaceId = "A1B2C3D4-0000-4000-8000-00000000000A"
const request = {
  profileId: "profile-1",
  projectId: "project-1",
  name: "Spike box",
  workspaceId: clientWorkspaceId
}
const unopenedGraceMs = 60 * 60 * 1000

const placedForClient = async () => {
  const harness = await sandboxHarness()
  await harness.machines.create(request)
  await harness.machines.settled()
  return harness
}

const advanceTo = async (
  harness: Awaited<ReturnType<typeof placedForClient>>,
  sinceCreate: number
) => {
  const createdAt = Date.parse((await harness.machines.list())[0]?.createdAt ?? "")
  await harness.deps.clock.sleep(createdAt + sinceCreate - harness.deps.clock.now())
}

describe("a workspace the client opens itself", () => {
  it("isn't created on the sandbox, so the client's first chat opens it", async () => {
    const harness = await placedForClient()

    expect(harness.toolCalls.map((call) => call.tool)).toEqual(["codevisor.projects.clone"])
    expect((await harness.machines.list())[0]).toMatchObject({
      state: "ready",
      workspaceId: clientWorkspaceId.toLowerCase()
    })
    expect((await harness.machines.list())[0]?.workspaceOpenedAt).toBeUndefined()
  })

  it("keeps the machine until the workspace opens, then watches it whatever its id's case", async () => {
    const harness = await placedForClient()
    await harness.machines.watch()
    expect(harness.provider.machines.size).toBe(1)

    harness.workspaces.push({ id: clientWorkspaceId, isArchived: false })
    await harness.machines.watch()
    expect((await harness.machines.list())[0]?.workspaceOpenedAt).toBe(
      new Date(harness.deps.clock.now()).toISOString()
    )

    const workspace = harness.workspaces[0]
    if (workspace !== undefined) workspace.isArchived = true
    await harness.machines.watch()
    expect((await harness.machines.list()).map((machine) => machine.state)).toEqual(["archived"])
  })

  it("tears the machine down when nobody opens its workspace within an hour", async () => {
    const harness = await placedForClient()
    await advanceTo(harness, unopenedGraceMs - 1)
    await harness.machines.watch()
    expect(harness.provider.machines.size).toBe(1)

    await advanceTo(harness, unopenedGraceMs)
    await harness.machines.watch()

    expect(harness.logs).toContain(
      "Destroying sandbox Spike box (id-1): nobody opened its workspace"
    )
    expect(await harness.machines.list()).toEqual([])
  })
})

describe("a project this machine doesn't have", () => {
  it("clones the repository the client named, or starts an empty project without one", async () => {
    const harness = await sandboxHarness()
    const elsewhere = { ...request, projectId: "on-the-laptop", projectName: "hello-world" }

    await harness.machines.create({
      ...elsewhere,
      repoUrl: "https://github.com/octocat/Hello-World.git"
    })
    await harness.machines.create({ ...elsewhere, workspaceId: undefined })
    await harness.machines.settled()

    expect(harness.toolCalls.map(({ tool, args }) => [tool, args["url"], args["name"]])).toEqual([
      ["codevisor.projects.clone", "https://github.com/octocat/Hello-World.git", "hello-world"],
      ["codevisor.projects.create_scratch", undefined, undefined],
      ["codevisor.workspaces.upsert", undefined, "Spike box"]
    ])
  })

  it("forgets the sandbox when its workspace is archived, since there's no project here to keep it in", async () => {
    const harness = await sandboxHarness()
    await harness.machines.create({
      ...request,
      projectId: "on-the-laptop",
      projectName: "hello-world"
    })
    await harness.machines.settled()
    harness.workspaces.push({ id: clientWorkspaceId, isArchived: true })

    await harness.machines.watch()

    expect(await harness.machines.list()).toEqual([])
    expect(harness.events).toEqual([])
  })

  it("restores into an empty slot when the archived workspace here is already gone", async () => {
    const harness = await sandboxHarness()
    await harness.records.put({
      id: "old",
      name: "Spike box",
      projectId: "project-1",
      provider: "e2b",
      profileId: "profile-1",
      accountId: "account-1",
      state: "archived",
      createdAt: "2026-10-01T00:00:00.000Z",
      workspaceId: "w-old"
    })

    await harness.machines.restore("w-old")
    await harness.machines.settled()

    expect(await harness.machines.list()).toMatchObject([{ state: "ready", workspaceId: "w-old" }])
    expect(harness.events).toEqual([])
  })
})
