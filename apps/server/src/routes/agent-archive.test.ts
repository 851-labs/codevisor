import { randomUUID } from "node:crypto"
import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { decode, StartedAgent } from "@codevisor/api"
import { Effect } from "effect"
import { describe, expect, it } from "vitest"

import { stopServer } from "../restart-test-support.js"
import { defaultServerConfig, startCodevisorServer } from "../server.js"
import { jsonRequest, run, runningServers, start, tempDirs, waitFor } from "../test-support.js"
import { idOf } from "./response-test-support.js"
import { finalAssistantText } from "./session-event-router.js"
import { sameId } from "./workspace-lookups.js"

const distinctAgentSessions = (agents: Awaited<ReturnType<typeof start>>["agents"]) => {
  const create = agents.createAgentSession
  let created = 0
  Object.assign(agents, {
    createAgentSession: (...args: Parameters<typeof create>) =>
      Effect.map(create(...args), (sharedId) => {
        created += 1
        const id = `${sharedId}-${created}`
        agents.sinks.set(id, args[2])
        return id
      })
  })
}

const workspaceWithHelper = async (helperPrompt: string) => {
  const running = await start()
  distinctAgentSessions(running.agents)
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
  const isArchived = async (agentId: string) =>
    (await run(services.db.getSessionSummary(agentId))).isArchived === true
  const agentSessionOf = async (agentId: string) =>
    (await run(services.db.getSessionSummary(agentId))).agentSessionId ?? ""
  const settled = async (agentId: string) =>
    (await run(services.db.getSessionSummary(agentId))).sidebarState !== "inProgress" &&
    (await run(services.db.listProcessingPromptQueue(agentId))).length === 0
  const turnIdOf = (agentSessionId: string) =>
    `turn-${running.agents.prompts.findLastIndex(([id]) => id === agentSessionId) + 1}`
  const startTurn = async (agentId: string) => {
    await waitFor(() => settled(agentId))
    const before = running.agents.prompts.length
    await prompt(agentId, "prompt until cancelled")
    await waitFor(() => running.agents.prompts.length > before)
    const agentSessionId = await agentSessionOf(agentId)
    await running.agents.emit(agentSessionId, {
      kind: "session.updated",
      subjectId: agentSessionId,
      payload: { initiatedBy: "user", turnId: turnIdOf(agentSessionId), turnState: "started" }
    })
  }
  const endTurn = async (agentId: string, finalText: string) => {
    const agentSessionId = await agentSessionOf(agentId)
    await running.agents.emit(agentSessionId, {
      kind: "session.output",
      subjectId: agentSessionId,
      payload: { role: "assistant", text: finalText }
    })
    await run(running.agents.cancel(agentSessionId))
  }
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
    workspace,
    isArchived,
    startTurn,
    endTurn,
    settled
  }
}

type Fixture = Awaited<ReturnType<typeof workspaceWithHelper>>

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

const scheduled = {
  archived: false,
  scheduled: true,
  message: expect.stringContaining("Archives when your turn ends")
}

describe("an agent archiving itself or its own workspace", () => {
  const entryPoints = [
    {
      name: "workspaces/:id/archive on its own workspace",
      call: (fixture: Fixture) => fixture.archiveWorkspace(fixture.workspaceId, fixture.parent),
      reply: (fixture: Fixture) => ({ workspaceId: fixture.workspaceId, ...scheduled })
    },
    {
      name: "agents/:id/archive on itself as the workspace's main chat",
      call: (fixture: Fixture) => fixture.archiveAgent(fixture.parent, fixture.parent),
      reply: (fixture: Fixture) => ({ agentId: fixture.parent, ...scheduled })
    }
  ]

  it.each(entryPoints)(
    "$name waits for the turn to end, then archives the workspace and every agent in it",
    async ({ call, reply }) => {
      const fixture = await workspaceWithHelper("Read the docs")
      const { services, parent, helper, workspace, isArchived, startTurn, endTurn } = fixture
      await fixture.helperTurnEnded()
      await startTurn(parent)

      const archived = await call(fixture)

      expect(archived.body).toEqual(reply(fixture))
      expect(await run(services.db.getDueDeferredArchive(parent))).toBeUndefined()
      expect(await workspace()).toMatchObject({ isArchived: false })

      console.log(
        "DBG A",
        JSON.stringify(fixture.agents.prompts).slice(0, 600),
        JSON.stringify(fixture.agents.creations),
        JSON.stringify(fixture.agents.loads)
      )
      await endTurn(parent, "All done, archiving now.")

      await waitFor(async () => (await workspace())?.isArchived === true)
      expect(await isArchived(parent)).toBe(true)
      expect(await isArchived(helper)).toBe(true)
      expect(await finalAssistantText(services, parent)).toBe("All done, archiving now.")
    }
  )

  it("archives only a side chat that archives itself, once its turn ends", async () => {
    const fixture = await workspaceWithHelper("prompt until cancelled")
    const { agents, parent, helper, workspace, isArchived, chatPanes, endTurn } = fixture
    await waitFor(() => agents.prompts.some(([, input]) => input === "prompt until cancelled"))

    const archived = await fixture.archiveAgent(helper, helper)

    expect(archived.body).toEqual({ agentId: helper, ...scheduled })
    expect(await isArchived(helper)).toBe(false)

    await endTurn(helper, "Done reading.")

    await waitFor(() => isArchived(helper))
    expect(await chatPanes()).toEqual([parent])
    expect(await isArchived(parent)).toBe(false)
    expect(await workspace()).toMatchObject({ isArchived: false })
  })

  it("cancels the archive when the user sends a message before the turn ends", async () => {
    const fixture = await workspaceWithHelper("Read the docs")
    const { services, parent, workspace, startTurn, endTurn } = fixture
    await fixture.helperTurnEnded()
    await startTurn(parent)
    await fixture.archiveWorkspace(fixture.workspaceId, parent)

    expect((await fixture.prompt(parent, "Wait, one more thing first")).status).toBe(202)
    await endTurn(parent, "Sure.")

    await waitFor(
      async () => (await run(services.db.getSessionSummary(parent))).sidebarState !== "inProgress"
    )
    expect(await run(services.db.listDueDeferredArchives)).toEqual([])
    expect(await workspace()).toMatchObject({ isArchived: false })
  })

  it("runs an archive whose turn ended just before the server stopped, once it starts again", async () => {
    const fixture = await workspaceWithHelper("Read the docs")
    const { server, services, parent, workspace, isArchived } = fixture
    await fixture.helperTurnEnded()
    await waitFor(() => fixture.settled(parent))
    await run(
      services.db.appendEvent("session.updated", parent, {
        initiatedBy: "user",
        turnId: "before-restart",
        turnState: "started"
      })
    )
    await fixture.archiveWorkspace(fixture.workspaceId, parent)
    await stopServer(server)
    await run(
      services.db.appendEvent("session.updated", parent, {
        stopReason: "end_turn",
        turnId: "before-restart",
        turnState: "ended"
      })
    )
    const finished = await run(services.db.getFinishedTurn(parent))
    await run(services.db.markTurnAnnounced(parent, finished?.revision ?? 0))
    expect(await workspace()).toMatchObject({ isArchived: false })

    runningServers.push(
      await run(
        startCodevisorServer(
          services,
          defaultServerConfig({ bootId: "test-boot", id: "server-a", port: 0 })
        )
      )
    )

    await waitFor(async () => (await workspace())?.isArchived === true)
    expect(await isArchived(parent)).toBe(true)
    expect(await run(services.db.listDueDeferredArchives)).toEqual([])
  })
})
