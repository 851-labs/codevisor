import { decode, SessionSummary } from "@codevisor/api"
import { Schema } from "effect"
import { describe, expect, it } from "vitest"

import { jsonRequest, waitFor } from "../test-support.js"
import { createBot, decodeBot, endedTurns, setUp, type Running } from "./bot-test-support.js"

const startBot = async () => {
  const running = await setUp()
  await running.addProject("api-project", "api")
  const bot = decodeBot((await createBot(running, { projectIds: ["api-project"] })).body)
  return { running, bot }
}

const send = (running: Running, sessionId: string, text: string) =>
  jsonRequest(running.server, `/v1/sessions/${sessionId}/messages`, {
    body: JSON.stringify({ text }),
    method: "POST"
  })

const nextCursor = decode(Schema.Struct({ next: Schema.Number }))

const list = (running: Running, sessionId: string, query = "") =>
  jsonRequest(running.server, `/v1/sessions/${sessionId}/messages${query}`)

describe("listing a bot's messages", () => {
  it("returns the latest messages oldest first, by sender, and pages back with next", async () => {
    const { running, bot } = await startBot()
    await jsonRequest(running.server, `/v1/sessions/${bot.sessionId}/prompt`, {
      body: JSON.stringify({ text: "do they have a 6.5?" }),
      method: "POST"
    })
    await waitFor(() => endedTurns(running, bot.sessionId) === 1)
    for (const text of ["Checking now.", "Yes, a 6.5 is in stock.", "Want me to order it?"]) {
      await send(running, bot.sessionId, text)
    }

    const everything = await list(running, bot.sessionId, "?limit=lots")
    const latest = await list(running, bot.sessionId, "?limit=2&sender=bot")
    const { next } = nextCursor(latest.body)
    const older = await list(running, bot.sessionId, `?limit=2&sender=bot&before=${next}`)

    expect(everything.body).toEqual({
      messages: [
        { sender: "user", text: "do they have a 6.5?", sentAt: expect.any(String) },
        { sender: "bot", text: "Checking now.", sentAt: expect.any(String) },
        { sender: "bot", text: "Yes, a 6.5 is in stock.", sentAt: expect.any(String) },
        { sender: "bot", text: "Want me to order it?", sentAt: expect.any(String) }
      ]
    })
    expect(latest.body).toMatchObject({
      messages: [{ text: "Yes, a 6.5 is in stock." }, { text: "Want me to order it?" }],
      next: expect.any(Number)
    })
    expect(older.body).toEqual({
      messages: [{ sender: "bot", text: "Checking now.", sentAt: expect.any(String) }]
    })
  })

  it("refuses an unknown sender and a chat that isn't a bot's", async () => {
    const { running, bot } = await startBot()
    const plain = decode(SessionSummary)(
      (
        await jsonRequest(running.server, "/v1/sessions", {
          body: JSON.stringify({ projectId: "api-project", harnessId: "codex", title: "Plain" }),
          method: "POST"
        })
      ).body
    )

    const unknownSender = await list(running, bot.sessionId, "?sender=someone")
    const notBot = await list(running, plain.id)

    expect(unknownSender.status).toBe(422)
    expect(notBot.status).toBe(403)
  })
})
