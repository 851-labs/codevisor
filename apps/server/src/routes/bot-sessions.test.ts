import { randomUUID } from "node:crypto"

import { decode, Workspace, WorkspacePane } from "@codevisor/api"
import { Effect, Schema } from "effect"
import { describe, expect, it, vi } from "vitest"

import { jsonRequest, listSubjectEvents, run, waitFor } from "../test-support.js"
import { createBot, decodeBot, setUp } from "./bot-test-support.js"

describe("bot chats", () => {
  it("starts a fresh agent thread when a bot's untouched thread can no longer be resumed", async () => {
    const running = await setUp()
    await running.addProject("api-project", "api")
    const bot = decodeBot((await createBot(running, { projectIds: ["api-project"] })).body)
    const prompt = (text: string) =>
      jsonRequest(running.server, `/v1/sessions/${bot.sessionId}/prompt`, {
        body: JSON.stringify({ text }),
        method: "POST"
      })
    const resumeFails = () =>
      vi
        .spyOn(running.agents, "loadAgentSession")
        .mockReturnValueOnce(Effect.die(new Error("no rollout found for thread id")))

    resumeFails()
    await prompt("hello world")

    await waitFor(() => running.agents.prompts.some(([, input]) => input === "hello world"))
    expect(running.agents.creations.filter(([, cwd]) => cwd === bot.rootPath)).toHaveLength(2)

    await run(
      running.services.db.appendConversationItem(bot.sessionId, "assistant", undefined, "hi", false)
    )
    resumeFails()
    await prompt("after a reply")

    await waitFor(() =>
      listSubjectEvents(running.services, bot.sessionId).some(
        (event) => event.kind === "session.error"
      )
    )
    expect(running.agents.creations.filter(([, cwd]) => cwd === bot.rootPath)).toHaveLength(2)

    await jsonRequest(running.server, "/v1/sessions", {
      body: JSON.stringify({
        id: "imported-chat",
        projectId: "api-project",
        harnessId: "codex",
        origin: "imported",
        agentSessionId: "native-thread"
      }),
      method: "POST"
    })
    const creationsBefore = running.agents.creations.length
    resumeFails()
    await jsonRequest(running.server, "/v1/sessions/imported-chat/prompt", {
      body: JSON.stringify({ text: "imported" }),
      method: "POST"
    })

    await waitFor(() =>
      listSubjectEvents(running.services, "imported-chat").some(
        (event) => event.kind === "session.error"
      )
    )
    expect(running.agents.creations).toHaveLength(creationsBefore)
    expect((await run(running.services.db.getSessionSummary("imported-chat"))).agentSessionId).toBe(
      "native-thread"
    )
  })

  it("attaches workspaces that the bot and its sub-agents create, and archives them with the bot", async () => {
    const running = await setUp()
    await running.addProject("api-project", "api")
    const bot = decodeBot((await createBot(running, { projectIds: ["api-project"] })).body)
    const createChat = (id: string, workspaceId?: string, parentSessionId?: string) =>
      jsonRequest(running.server, "/v1/sessions", {
        body: JSON.stringify({
          id,
          projectId: "api-project",
          harnessId: "codex",
          ...(parentSessionId === undefined ? {} : { parentSessionId }),
          ...(workspaceId === undefined ? {} : { workspaceId })
        }),
        method: "POST"
      })
    const workspace = async (id: string) =>
      decode(Schema.Array(Workspace))(
        (await jsonRequest(running.server, "/v1/workspaces")).body
      ).find((candidate) => candidate.id === id)

    expect((await createChat("child-chat", "child-ws", bot.sessionId)).status).toBe(201)
    expect((await createChat("grandchild-chat", "grandchild-ws", "child-chat")).status).toBe(201)
    await createChat("plain-chat", "plain-ws")
    await createChat("plain-child", "plain-child-ws", "plain-chat")
    await createChat("loose-chat")
    await createChat("loose-child", "loose-child-ws", "loose-chat")
    await createChat("ghost-child", "ghost-child-ws", "ghost-chat")
    const created = await jsonRequest(running.server, "/v1/workspaces", {
      body: JSON.stringify({
        workspace: {
          id: "direct-ws",
          projectId: "api-project",
          name: "Direct",
          hasCustomName: true
        },
        session: { projectId: "api-project", harnessId: "codex", parentSessionId: bot.sessionId }
      }),
      method: "POST"
    })

    expect(created.status).toBe(201)
    expect(await workspace("child-ws")).toMatchObject({ botId: bot.id, isArchived: false })
    expect(await workspace("direct-ws")).toMatchObject({ botId: bot.id })
    expect(await workspace("grandchild-ws")).toMatchObject({ botId: bot.id })
    for (const unattached of ["plain-ws", "plain-child-ws", "loose-child-ws", "ghost-child-ws"]) {
      expect((await workspace(unattached))?.botId).toBeUndefined()
    }

    expect(
      (await jsonRequest(running.server, `/v1/bots/${bot.id}`, { method: "DELETE" })).status
    ).toBe(204)

    expect(await workspace("child-ws")).toMatchObject({ isArchived: true })
    expect((await workspace("child-ws"))?.botId).toBeUndefined()
    expect(await workspace("direct-ws")).toMatchObject({ isArchived: true })
    expect(await workspace("grandchild-ws")).toMatchObject({ isArchived: true })
    expect(await workspace("plain-child-ws")).toMatchObject({ isArchived: false })
  })

  it("refuses new tabs in a bot's own workspace but not in its sub-agents' workspaces", async () => {
    const running = await setUp()
    await running.addProject("api-project", "api")
    const bot = decodeBot((await createBot(running, { projectIds: ["api-project"] })).body)
    const panesIn = async (workspaceId: string) =>
      decode(Schema.Array(WorkspacePane))(
        (await jsonRequest(running.server, "/v1/workspace-panes")).body
      ).filter((pane) => pane.workspaceId === workspaceId)
    const putPane = (workspaceId: string, paneId: string, body: Record<string, unknown>) =>
      jsonRequest(running.server, `/v1/workspaces/${workspaceId}/panes/${paneId}`, {
        body: JSON.stringify(body),
        method: "PUT"
      })
    const terminal = { providerId: "codevisor", paneType: "terminal", title: "Terminal" }
    const [chatPane] = await panesIn(bot.workspaceId)
    if (chatPane === undefined) throw new Error("missing the bot's chat pane")

    const refused = await putPane(bot.workspaceId, randomUUID(), terminal)

    expect(refused.status).toBe(409)
    expect(refused.body).toMatchObject({
      error: "Cannot open a new tab in this workspace: it belongs to the bot Release Helper"
    })
    expect(await panesIn(bot.workspaceId)).toEqual([chatPane])
    expect(
      (
        await putPane(bot.workspaceId, chatPane.id, {
          providerId: chatPane.providerId,
          paneType: chatPane.paneType,
          resourceKind: "session",
          resourceId: bot.sessionId,
          title: "Renamed"
        })
      ).status
    ).toBe(200)

    await jsonRequest(running.server, "/v1/sessions", {
      body: JSON.stringify({
        id: "child-chat",
        projectId: "api-project",
        harnessId: "codex",
        parentSessionId: bot.sessionId,
        workspaceId: "child-ws"
      }),
      method: "POST"
    })

    expect((await putPane("child-ws", randomUUID(), terminal)).status).toBe(200)
    expect(await panesIn("child-ws")).toHaveLength(2)
  })
})
