import { decode, SessionSummary } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import { jsonRequest, listSubjectEvents, run, waitFor } from "../test-support.js"
import { createBot, decodeBot, setUp, type Running } from "./bot-test-support.js"

const decodeSummary = decode(SessionSummary)

const post = (running: Running, path: string, body: Record<string, unknown>) =>
  jsonRequest(running.server, path, { body: JSON.stringify(body), method: "POST" })

const startBot = async () => {
  const running = await setUp()
  await running.addProject("api-project", "api")
  const bot = decodeBot(
    (await createBot(running, { projectIds: ["api-project"], conversational: true })).body
  )
  return { running, bot }
}

const summary = (running: Running, sessionId: string) =>
  run(running.services.db.getSessionSummary(sessionId))

const publishedAttention = (running: Running, sessionId: string) =>
  listSubjectEvents(running.services, sessionId)
    .filter((event) => event.kind === "session.attention.updated")
    .map((event) => decodeSummary(event.payload))

const finishSilentTurn = async (running: Running, sessionId: string) => {
  await post(running, `/v1/sessions/${sessionId}/prompt`, {
    text: "release finished",
    fromSessionId: "release-agent"
  })
  await waitFor(() => running.agents.prompts.length === 1)
  await waitFor(async () => (await summary(running, sessionId)).sidebarState === "idle")
}

describe("bot conversation attention", () => {
  it("stays read through a turn that sends the user nothing", async () => {
    const { running, bot } = await startBot()

    await finishSilentTurn(running, bot.sessionId)

    expect(await summary(running, bot.sessionId)).toMatchObject({ unreadCount: 0 })
    expect(publishedAttention(running, bot.sessionId).map((s) => s.unreadCount)).not.toContain(1)
  })

  it("publishes unread with the message's preview when the bot sends one", async () => {
    const { running, bot } = await startBot()

    await post(running, `/v1/sessions/${bot.sessionId}/messages`, { text: "Release is out" })

    expect(publishedAttention(running, bot.sessionId).at(-1)).toMatchObject({
      unreadCount: 1,
      sidebarState: "unread",
      latestBotMessage: { text: "Release is out", attachmentNames: [] }
    })
  })

  it("publishes the read so every device clears the chat", async () => {
    const { running, bot } = await startBot()
    await post(running, `/v1/sessions/${bot.sessionId}/messages`, { text: "Release is out" })

    await post(running, `/v1/sessions/${bot.sessionId}/read`, { throughSequence: 1 })

    expect(publishedAttention(running, bot.sessionId).at(-1)).toMatchObject({
      unreadCount: 0,
      lastSeenAttentionSequence: 1,
      sidebarState: "idle"
    })
  })
})
