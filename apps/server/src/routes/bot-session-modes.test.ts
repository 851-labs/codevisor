import { AGENT_VERB_HEADER } from "@codevisor/api"
import { describe, expect, it, vi } from "vitest"

import { jsonRequest, run } from "../test-support.js"
import { field } from "../unknown-values.js"
import { createBot, decodeBot, setUp } from "./bot-test-support.js"

const post = (running: Awaited<ReturnType<typeof setUp>>, path: string, body: unknown) =>
  jsonRequest(running.server, path, { body: JSON.stringify(body), method: "POST" })

describe("bot plan and goal modes", () => {
  it("starts and reloads a bot's own chat as a bot session, and other chats as usual", async () => {
    const running = await setUp()
    await running.addProject("api-project", "api")
    const creates = vi.spyOn(running.agents, "createAgentSession")
    const loads = vi.spyOn(running.agents, "loadAgentSession")

    const bot = decodeBot((await createBot(running, { projectIds: ["api-project"] })).body)
    await post(running, "/v1/sessions", {
      id: "chat-1",
      projectId: "api-project",
      harnessId: "codex"
    })
    await post(running, `/v1/sessions/${bot.sessionId}/connect`, {})
    await post(running, "/v1/sessions/chat-1/connect", {})

    expect(creates.mock.calls.map((call) => call[5]?.bot)).toEqual([true, undefined])
    expect(loads.mock.calls.map((call) => call[6]?.bot)).toEqual([true, undefined])
  })

  it("refuses plan mode and goals for a bot's chat, and lets other picks through", async () => {
    const running = await setUp()
    await running.addProject("api-project", "api")
    const bot = decodeBot((await createBot(running, { projectIds: ["api-project"] })).body)
    const agentSessionId = (await run(running.services.db.getSessionSummary(bot.sessionId)))
      .agentSessionId!
    await post(running, `/v1/sessions/${bot.sessionId}/connect`, {})
    await running.agents.emit(agentSessionId, {
      kind: "session.updated",
      subjectId: agentSessionId,
      payload: {
        configOptions: [
          {
            category: "mode",
            currentValue: "build",
            id: "agent",
            name: "Agent",
            options: [{ name: "Build", value: "build" }]
          }
        ]
      }
    })
    const action = (path: string, body: unknown) =>
      post(running, `/v1/sessions/${bot.sessionId}/${path}`, body).then((response) => [
        response.status,
        field(response.body, "error")
      ])

    expect(await action("goal", { objective: "Ship the release" })).toEqual([
      409,
      "Bots can't use goals"
    ])
    expect(await action("mode", { modeId: "plan" })).toEqual([409, "Bots can't use plan mode"])
    expect(await action("config", { configId: "mode", value: "plan" })).toEqual([
      409,
      "Bots can't use plan mode"
    ])
    expect(await action("config", { configId: "agent", value: "Plan" })).toEqual([
      409,
      "Bots can't use plan mode"
    ])
    expect((await action("config", { configId: "model", value: "planck" }))[0]).toBe(202)
    expect((await action("config", { configId: "agent", value: "build" }))[0]).toBe(202)
    expect((await action("mode", { modeId: "bypassPermissions" }))[0]).toBe(202)
    expect(running.agents.goals).toEqual([])
    expect(running.agents.prompts).toEqual([])
    expect(running.agents.modes).toEqual([[agentSessionId, "bypassPermissions"]])
  })

  it("refuses an agent's verbs on a bot's chat and takes the same requests from the app", async () => {
    const running = await setUp()
    await running.addProject("api-project", "api")
    const bot = decodeBot((await createBot(running, { projectIds: ["api-project"] })).body)
    await post(running, "/v1/sessions", {
      id: "chat-1",
      projectId: "api-project",
      harnessId: "codex"
    })
    const asAgent = (sessionId: string, verb: string) =>
      jsonRequest(running.server, `/v1/sessions/${sessionId}/cancel`, {
        headers: { [AGENT_VERB_HEADER]: verb },
        method: "POST"
      })

    const refused = await asAgent(bot.sessionId, "cancel")

    expect([refused.status, field(refused.body, "error")]).toEqual([
      409,
      "Cannot cancel Release Helper: it is a bot, not an agent. Bots belong to the user"
    ])
    expect((await asAgent("chat-1", "cancel")).status).not.toBe(409)
    expect((await post(running, `/v1/sessions/${bot.sessionId}/cancel`, {})).status).not.toBe(409)
  })

  it("leaves plan mode and goals alone for a regular chat", async () => {
    const running = await setUp()
    await running.addProject("api-project", "api")
    await post(running, "/v1/sessions", {
      id: "chat-1",
      projectId: "api-project",
      harnessId: "codex"
    })

    expect((await post(running, "/v1/sessions/chat-1/mode", { modeId: "plan" })).status).toBe(202)
    expect(
      (await post(running, "/v1/sessions/chat-1/config", { configId: "mode", value: "plan" }))
        .status
    ).toBe(202)
    expect(
      (await post(running, "/v1/sessions/chat-1/goal", { objective: "Ship the release" })).status
    ).toBe(202)
  })
})
