import { randomUUID } from "node:crypto"
import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { decode, StartedAgent } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import { jsonRequest, run, start, tempDirs, waitFor } from "../test-support.js"
import { idOf } from "./response-test-support.js"
import { sameId } from "./workspace-lookups.js"

const workspaceWithHelper = async (helperPrompt: string) => {
  const running = await start()
  const { server, services } = running
  const folderPath = mkdtempSync(join(tmpdir(), "codevisor-agent-archive-"))
  tempDirs.push(folderPath)
  const projectId = idOf(
    (
      await jsonRequest(server, "/v1/projects", {
        body: JSON.stringify({ folderPath }),
        method: "POST"
      })
    ).body
  )
  const workspaceId = randomUUID()
  const createChat = async (body: Record<string, unknown>) =>
    idOf(
      (
        await jsonRequest(server, "/v1/sessions", {
          body: JSON.stringify({ projectId, harnessId: "codex", ...body }),
          method: "POST"
        })
      ).body
    )
  const parent = await createChat({ workspaceId })
  const helper = decode(StartedAgent)(
    (
      await jsonRequest(server, "/v1/agents", {
        body: JSON.stringify({
          prompt: helperPrompt,
          title: "Read the docs",
          checkout: "shared",
          callerAgentId: parent
        }),
        method: "POST"
      })
    ).body
  ).agentId
  const archiveWorkspace = (id: string, callerAgentId: string) =>
    jsonRequest(server, `/v1/workspaces/${id}/archive`, {
      body: JSON.stringify({ callerAgentId }),
      method: "POST"
    })
  const archiveAgent = (agentId: string, callerAgentId: string) =>
    jsonRequest(server, `/v1/agents/${agentId}/archive`, {
      body: JSON.stringify({ callerAgentId }),
      method: "POST"
    })
  const prompt = (agentId: string, text: string) =>
    jsonRequest(server, `/v1/sessions/${agentId}/prompt`, {
      body: JSON.stringify({ text, messageId: randomUUID() }),
      method: "POST"
    })
  const chatPanes = async () =>
    (await run(services.db.listWorkspacePanes))
      .filter((pane) => pane.resourceKind === "session")
      .map((pane) => pane.resourceId)
  const helperTurnEnded = () =>
    waitFor(() =>
      running.agents.prompts.some(
        ([, input]) => typeof input === "string" && input.startsWith("<codevisor-event")
      )
    )
  const workspace = async () =>
    (await run(services.db.listWorkspaces)).find((candidate) => candidate.id === workspaceId)
  return {
    ...running,
    workspaceId,
    parent,
    helper,
    createChat,
    archiveWorkspace,
    archiveAgent,
    prompt,
    chatPanes,
    helperTurnEnded,
    workspace
  }
}

describe("POST /v1/agents/:id/archive", () => {
  it("stops a shared helper, archives its chat and closes its tab, leaving the caller's workspace alone", async () => {
    const { agents, services, workspaceId, parent, helper, archiveAgent, chatPanes, workspace } =
      await workspaceWithHelper("prompt until cancelled")
    await waitFor(
      async () => (await run(services.db.getSessionSummary(helper))).sidebarState === "inProgress"
    )
    await run(services.db.createPromptQueueItem(helper, "next task"))
    expect(await chatPanes()).toEqual([parent, helper])
    expect(await run(services.db.listSessionSubscriptions(parent))).toEqual([
      expect.objectContaining({ targetSessionId: helper })
    ])

    const archived = await archiveAgent(helper, parent)

    expect(archived.body).toEqual({ agentId: helper, archived: true })
    expect(agents.cancellations).toHaveLength(1)
    expect(await run(services.db.listSessionSubscriptions(parent))).toEqual([])
    expect(await run(services.db.listPromptQueue(helper))).toEqual([])
    expect(await chatPanes()).toEqual([parent])
    expect(await run(services.db.getSessionSummary(helper))).toMatchObject({
      workspaceId,
      isArchived: true
    })
    expect((await run(services.db.getSessionSummary(parent))).isArchived).toBeUndefined()
    expect(await workspace()).toMatchObject({ isArchived: false })
  })

  it("refuses a prompt to a helper once it is archived", async () => {
    const { parent, helper, archiveAgent, helperTurnEnded, prompt } =
      await workspaceWithHelper("Read the docs")
    await helperTurnEnded()
    await archiveAgent(helper, parent)

    const refused = await prompt(helper, "one more thing")

    expect(refused.status).toBe(409)
    expect(refused.body).toEqual({ error: "This chat is archived" })
  })

  it("lists an archived agent as archived", async () => {
    const { server, parent, helper, archiveAgent, helperTurnEnded } =
      await workspaceWithHelper("Read the docs")
    await helperTurnEnded()
    await archiveAgent(helper, parent)

    const listed = await jsonRequest(server, `/v1/agents?createdByAgentId=${parent}`)

    expect(listed.body).toEqual({
      items: [expect.objectContaining({ agentId: helper, archived: true })]
    })
  })

  it("archives an idle shared helper without cancelling anything", async () => {
    const { agents, parent, helper, archiveAgent, chatPanes, helperTurnEnded } =
      await workspaceWithHelper("Read the docs")
    await helperTurnEnded()

    const archived = await archiveAgent(helper, parent)

    expect(archived.body).toEqual({ agentId: helper, archived: true })
    expect(agents.cancellations).toEqual([])
    expect(await chatPanes()).toEqual([parent])
  })

  it("refuses to archive the caller itself and changes nothing", async () => {
    const { parent, archiveAgent, chatPanes, workspace } =
      await workspaceWithHelper("Read the docs")

    const archived = await archiveAgent(parent, parent)

    expect(archived.status).toBe(422)
    expect(JSON.stringify(archived.body)).toContain("you can't archive yourself")
    expect(await chatPanes()).toHaveLength(2)
    expect(await workspace()).toMatchObject({ isArchived: false })
  })

  it("archives the workspace of an agent that has its own, and leaves the caller's alone", async () => {
    const { services, parent, createChat, archiveAgent, workspace } =
      await workspaceWithHelper("Read the docs")
    const ownWorkspaceId = randomUUID()
    const worker = await createChat({ workspaceId: ownWorkspaceId })
    const workerWorkspace = async () =>
      (await run(services.db.listWorkspaces)).find((candidate) =>
        sameId(candidate.id, ownWorkspaceId)
      )

    const archived = await archiveAgent(worker, parent)

    expect(archived.body).toEqual({ agentId: worker, archived: true })
    expect(await workerWorkspace()).toMatchObject({ isArchived: true })
    expect(await run(services.db.getSessionSummary(worker))).toMatchObject({ isArchived: true })
    expect(await workspace()).toMatchObject({ isArchived: false })
  })

  it("archives an agent's own workspace for a caller on another machine, who is not named", async () => {
    const { server, services, createChat, workspace } = await workspaceWithHelper("Read the docs")
    const ownWorkspaceId = randomUUID()
    const worker = await createChat({ workspaceId: ownWorkspaceId })

    const archived = await jsonRequest(server, `/v1/agents/${worker}/archive`, {
      body: JSON.stringify({}),
      method: "POST"
    })

    expect(archived.body).toEqual({ agentId: worker, archived: true })
    expect(await run(services.db.getSessionSummary(worker))).toMatchObject({ isArchived: true })
    expect(await workspace()).toMatchObject({ isArchived: false })
  })

  it("archives only the chat of another workspace's side chat instead of archiving that workspace", async () => {
    const { helper, createChat, archiveAgent, chatPanes, workspace } =
      await workspaceWithHelper("Read the docs")
    const outsider = await createChat({ workspaceId: randomUUID() })

    const archived = await archiveAgent(helper, outsider)

    expect(archived.body).toEqual({ agentId: helper, archived: true })
    expect(await chatPanes()).not.toContain(helper)
    expect(await workspace()).toMatchObject({ isArchived: false })
  })

  it("rejects an unknown caller and an unknown agent", async () => {
    const { parent, helper, archiveAgent, chatPanes } = await workspaceWithHelper("Read the docs")

    expect((await archiveAgent(helper, randomUUID())).status).toBe(422)
    expect((await archiveAgent(randomUUID(), parent)).status).toBeGreaterThanOrEqual(400)
    expect(await chatPanes()).toHaveLength(2)
  })
})

describe("POST /v1/workspaces/:id/archive", () => {
  it("refuses the caller's own workspace and points at agents.archive", async () => {
    const { workspaceId, parent, archiveWorkspace, workspace } =
      await workspaceWithHelper("Read the docs")

    const archived = await archiveWorkspace(workspaceId, parent)

    expect(archived.status).toBe(422)
    expect(JSON.stringify(archived.body)).toContain("agents.archive")
    expect(await workspace()).toMatchObject({ isArchived: false })
  })

  it("archives another agent's workspace and rejects unknown callers and workspaces", async () => {
    const { workspaceId, createChat, archiveWorkspace, workspace } =
      await workspaceWithHelper("Read the docs")
    const outsider = await createChat({ workspaceId: randomUUID() })

    expect((await archiveWorkspace(workspaceId, randomUUID())).status).toBe(422)
    expect((await archiveWorkspace(randomUUID(), outsider)).status).toBe(404)
    expect(await workspace()).toMatchObject({ isArchived: false })

    const archived = await archiveWorkspace(workspaceId, outsider)

    expect(archived.body).toEqual({ workspaceId, archived: true })
    expect(await workspace()).toMatchObject({ isArchived: true })
  })
})
