import { randomUUID } from "node:crypto"
import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { decode, StartedAgent } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import { jsonRequest, run, start, tempDirs, waitFor } from "../test-support.js"
import { idOf } from "./response-test-support.js"

const workspaceWithHelper = async (helperPrompt: string) => {
  const running = await start()
  const { server, services } = running
  const folderPath = mkdtempSync(join(tmpdir(), "codevisor-agent-close-"))
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
          isolation: "shared",
          callerAgentId: parent
        }),
        method: "POST"
      })
    ).body
  ).agentId
  const close = (agentId: string, callerAgentId: string) =>
    jsonRequest(server, `/v1/agents/${agentId}/close`, {
      body: JSON.stringify({ callerAgentId }),
      method: "POST"
    })
  const archiveWorkspace = (id: string, callerAgentId: string) =>
    jsonRequest(server, `/v1/workspaces/${id}/archive`, {
      body: JSON.stringify({ callerAgentId }),
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
    close,
    archiveWorkspace,
    chatPanes,
    helperTurnEnded,
    workspace
  }
}

describe("POST /v1/agents/:id/close", () => {
  it("stops the agent and closes only its chat tab, keeping the chat and the workspace", async () => {
    const { agents, services, workspaceId, parent, helper, close, chatPanes, workspace } =
      await workspaceWithHelper("prompt until cancelled")
    await waitFor(
      async () => (await run(services.db.getSessionSummary(helper))).sidebarState === "inProgress"
    )
    await run(services.db.createPromptQueueItem(helper, "next task"))
    expect(await chatPanes()).toEqual([parent, helper])
    expect(await run(services.db.listSessionSubscriptions(parent))).toEqual([
      expect.objectContaining({ targetSessionId: helper })
    ])

    const closed = await close(helper, parent)

    expect(closed.body).toEqual({ agentId: helper, workspaceId, closed: true })
    expect(agents.cancellations).toHaveLength(1)
    expect(await run(services.db.listSessionSubscriptions(parent))).toEqual([])
    expect(await run(services.db.listPromptQueue(helper))).toEqual([])
    expect(await chatPanes()).toEqual([parent])
    expect(await run(services.db.getSessionSummary(helper))).toMatchObject({ workspaceId })
    expect(await workspace()).toMatchObject({ isArchived: false })
  })

  it("closes an idle agent's tab without cancelling anything", async () => {
    const { agents, workspaceId, parent, helper, close, chatPanes, helperTurnEnded } =
      await workspaceWithHelper("Read the docs")
    await helperTurnEnded()

    const closed = await close(helper, parent)

    expect(closed.body).toEqual({ agentId: helper, workspaceId, closed: true })
    expect(agents.cancellations).toEqual([])
    expect(await chatPanes()).toEqual([parent])
  })

  it("refuses to close the caller itself and changes nothing", async () => {
    const { helper, close, chatPanes } = await workspaceWithHelper("Read the docs")

    const closed = await close(helper, helper)

    expect(closed.status).toBe(422)
    expect(JSON.stringify(closed.body)).toContain("you can't close yourself")
    expect(await chatPanes()).toHaveLength(2)
  })

  it("points an agent outside the caller's workspace at workspaces.archive", async () => {
    const { workspaceId, helper, createChat, close, chatPanes, workspace } =
      await workspaceWithHelper("Read the docs")
    const outsider = await createChat({ workspaceId: randomUUID() })
    const loose = await createChat({})

    const fromOutside = await close(helper, outsider)
    const fromLoose = await close(helper, loose)
    const ofLoose = await close(loose, outsider)

    expect(fromOutside.status).toBe(422)
    expect(JSON.stringify(fromOutside.body)).toContain(
      `workspaces.archive({ workspaceId: \\"${workspaceId}\\" })`
    )
    expect(fromLoose.status).toBe(422)
    expect(ofLoose.status).toBe(422)
    expect(JSON.stringify(ofLoose.body)).not.toContain("workspaces.archive")
    expect(await chatPanes()).toHaveLength(3)
    expect(await workspace()).toMatchObject({ isArchived: false })
  })

  it("rejects an unknown caller", async () => {
    const { helper, close } = await workspaceWithHelper("Read the docs")

    expect((await close(helper, randomUUID())).status).toBe(422)
  })
})

describe("POST /v1/workspaces/:id/archive", () => {
  it("refuses the caller's own workspace and points at agents.close", async () => {
    const { workspaceId, parent, archiveWorkspace, workspace } =
      await workspaceWithHelper("Read the docs")

    const archived = await archiveWorkspace(workspaceId, parent)

    expect(archived.status).toBe(422)
    expect(JSON.stringify(archived.body)).toContain("agents.close")
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
