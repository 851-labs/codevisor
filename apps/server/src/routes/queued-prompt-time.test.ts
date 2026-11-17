import { BotConversationPage, decode, SessionDetail } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import { jsonRequest, waitFor } from "../test-support.js"
import { createBot, decodeBot, setUp, type Running } from "./bot-test-support.js"

const post = (running: Running, path: string, body: Record<string, unknown>) =>
  jsonRequest(running.server, path, { body: JSON.stringify(body), method: "POST" })

const startBots = async () => {
  const running = await setUp()
  await running.addProject("api-project", "api")
  const create = (name: string) =>
    createBot(running, { name, projectIds: ["api-project"] }).then(({ body }) => decodeBot(body))
  return { running, lead: await create("Lead"), scout: await create("Scout") }
}

const holdTurn = async (running: Running, sessionId: string) => {
  const before = running.agents.prompts.length
  await post(running, `/v1/sessions/${sessionId}/prompt`, { text: "slow prompt" })
  await waitFor(() => running.agents.prompts.length > before)
}

const transcriptItems = async (running: Running, sessionId: string) =>
  decode(SessionDetail)((await jsonRequest(running.server, `/v1/sessions/${sessionId}`)).body)
    .conversation

const sentAt = async (running: Running, sessionId: string, text: string) => {
  const page = decode(BotConversationPage)(
    (await jsonRequest(running.server, `/v1/sessions/${sessionId}/conversation`)).body
  )
  return page.messages.find((message) => message.text === text)?.createdAt
}

const isScout = (item: { readonly text: string }) => item.text.includes("Scout finished.")

describe("queued prompt time", () => {
  it("dates an event the bot reads after a busy turn by when it arrived", async () => {
    const { running, lead, scout } = await startBots()
    await holdTurn(running, lead.sessionId)

    await post(running, `/v1/bots/${lead.id}/messages`, {
      text: "Scout finished.",
      sentByAgentId: scout.sessionId
    })
    await post(running, `/v1/sessions/${lead.sessionId}/prompt`, { text: "Sent after Scout" })
    running.agents.releasePrompt()

    await waitFor(async () => (await transcriptItems(running, lead.sessionId)).some(isScout))
    const event = (await transcriptItems(running, lead.sessionId)).find(isScout)!
    const later = await sentAt(running, lead.sessionId, "Sent after Scout")
    expect(later).toBeDefined()
    expect(Date.parse(event.createdAt)).toBeLessThanOrEqual(Date.parse(later!))
  })
})
