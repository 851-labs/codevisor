import { decode, DetachedAgent, SessionSummary, Workspace } from "@codevisor/api"
import { Schema } from "effect"
import { describe, expect, it } from "vitest"

import { archiveJobs } from "../archive-jobs.js"
import { jsonRequest } from "../test-support.js"
import { createBot, decodeBot, setUp, type Running } from "./bot-test-support.js"

const chatIn = (running: Running, id: string, references: Record<string, string> = {}) =>
  jsonRequest(running.server, "/v1/sessions", {
    body: JSON.stringify({
      id,
      projectId: "api-project",
      harnessId: "codex",
      workspaceId: `ws-${id}`,
      ...(references.createdByAgentId === undefined ? {} : { createdBy: "agent" }),
      ...references
    }),
    method: "POST"
  })

const archivedIds = async (running: Running): Promise<ReadonlyArray<string>> => {
  await archiveJobs(running.services).idle()
  const workspaces = decode(Schema.Array(Workspace))(
    (await jsonRequest(running.server, "/v1/workspaces")).body
  )
  return workspaces.filter((workspace) => workspace.isArchived).map((workspace) => workspace.id)
}

const looseChat = (running: Running, id: string, ownerId: string) =>
  jsonRequest(running.server, "/v1/sessions", {
    body: JSON.stringify({
      id,
      projectId: "api-project",
      harnessId: "codex",
      createdBy: "agent",
      createdByAgentId: ownerId
    }),
    method: "POST"
  })

const archivedChats = async (running: Running): Promise<ReadonlyArray<string>> => {
  await archiveJobs(running.services).idle()
  const chats = decode(Schema.Array(SessionSummary))(
    (await jsonRequest(running.server, "/v1/sessions")).body
  )
  return chats
    .filter((chat) => chat.isArchived === true)
    .map((chat) => chat.id)
    .toSorted()
}

const startedFamily = async () => {
  const running = await setUp()
  await running.addProject("api-project", "api")
  await chatIn(running, "lead")
  await chatIn(running, "child", { createdByAgentId: "lead" })
  await chatIn(running, "grandchild", { createdByAgentId: "child" })
  await chatIn(running, "fork", { forkedFromAgentId: "lead" })
  await chatIn(running, "unrelated")
  return running
}

describe("archiving an agent's workspace", () => {
  it("archives every agent it started, and theirs, but not forks or other workspaces", async () => {
    const running = await startedFamily()

    const archived = await jsonRequest(running.server, "/v1/workspaces/ws-lead", {
      body: JSON.stringify({ isArchived: true }),
      method: "PATCH"
    })

    expect(archived.status).toBe(200)
    expect([...(await archivedIds(running))].toSorted()).toEqual([
      "ws-child",
      "ws-grandchild",
      "ws-lead"
    ])
  })

  it("archives the agents it owns that have no workspace, and what they own in turn", async () => {
    const running = await startedFamily()
    await looseChat(running, "loose", "lead")
    await looseChat(running, "loose-child", "loose")
    await chatIn(running, "loose-grandchild", { createdByAgentId: "loose-child" })
    await looseChat(running, "elsewhere", "unrelated")

    await jsonRequest(running.server, "/v1/workspaces/ws-lead", {
      body: JSON.stringify({ isArchived: true }),
      method: "PATCH"
    })

    expect(await archivedChats(running)).toEqual([
      "child",
      "grandchild",
      "lead",
      "loose",
      "loose-child",
      "loose-grandchild"
    ])
  })

  it("archives what a chat owns when an agent archives that chat", async () => {
    const running = await startedFamily()
    await looseChat(running, "loose", "lead")
    await looseChat(running, "loose-child", "loose")

    const archived = await jsonRequest(running.server, "/v1/agents/loose/archive", {
      body: JSON.stringify({ callerAgentId: "lead" }),
      method: "POST"
    })

    expect(archived.body).toEqual({ agentId: "loose", archived: true })
    expect(await archivedChats(running)).toEqual(["loose", "loose-child"])
  })

  it("leaves an agent that stands alone, and the agents it started", async () => {
    const running = await startedFamily()
    const detached = await jsonRequest(running.server, "/v1/agents/child/detach", {
      body: JSON.stringify({}),
      method: "POST"
    })

    await jsonRequest(running.server, "/v1/workspaces/ws-lead", {
      body: JSON.stringify({ isArchived: true }),
      method: "PATCH"
    })

    expect(detached.body).toEqual({ agentId: "child", workspaceId: "ws-child", detached: true })
    expect(await archivedIds(running)).toEqual(["ws-lead"])
  })

  it("moves a helper that shares its starter's workspace into one of its own when it is detached", async () => {
    const running = await startedFamily()
    await jsonRequest(running.server, "/v1/sessions", {
      body: JSON.stringify({
        id: "helper",
        projectId: "api-project",
        harnessId: "codex",
        workspaceId: "ws-lead",
        createdBy: "agent",
        createdByAgentId: "lead"
      }),
      method: "POST"
    })

    const detached = await jsonRequest(running.server, "/v1/agents/helper/detach", {
      body: JSON.stringify({}),
      method: "POST"
    })
    const listed = await jsonRequest(running.server, "/v1/agents?createdByAgentId=lead")
    await jsonRequest(running.server, "/v1/workspaces/ws-lead", {
      body: JSON.stringify({ isArchived: true }),
      method: "PATCH"
    })

    const own = decode(DetachedAgent)(detached.body).workspaceId
    expect(own).not.toBe("ws-lead")
    expect(listed.body).toEqual({
      items: expect.arrayContaining([
        expect.objectContaining({ agentId: "helper", workspaceId: own, standalone: true })
      ])
    })
    expect(await archivedIds(running)).not.toContain(own)
  })

  it("refuses to detach a chat no agent started", async () => {
    const running = await startedFamily()

    const refused = await jsonRequest(running.server, "/v1/agents/lead/detach", {
      body: JSON.stringify({}),
      method: "POST"
    })

    expect(refused).toMatchObject({
      status: 422,
      body: { error: expect.stringContaining("already stands alone") }
    })
  })

  it("does the same when an agent archives the workspace with workspaces.archive", async () => {
    const running = await startedFamily()

    const archived = await jsonRequest(running.server, "/v1/workspaces/ws-child/archive", {
      body: JSON.stringify({}),
      method: "POST"
    })

    expect(archived.status).toBe(200)
    expect([...(await archivedIds(running))].toSorted()).toEqual(["ws-child", "ws-grandchild"])
  })

  it("archives the agents a bot started when the bot is archived", async () => {
    const running = await setUp()
    await running.addProject("api-project", "api")
    const bot = decodeBot((await createBot(running, { projectIds: ["api-project"] })).body)
    await chatIn(running, "bot-task", { createdByAgentId: bot.sessionId })

    await jsonRequest(running.server, `/v1/bots/${bot.id}`, {
      body: JSON.stringify({ isArchived: true }),
      method: "PATCH"
    })

    expect(await archivedIds(running)).toEqual(["ws-bot-task"])
  })
})
