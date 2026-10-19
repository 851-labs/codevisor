import { randomUUID } from "node:crypto"
import { writeFileSync } from "node:fs"
import { join } from "node:path"

import { BotConversationPage, decode, SessionSummary } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import { jsonRequest, run, waitFor } from "../test-support.js"
import { createBot, decodeBot, setUp, type Running } from "./bot-test-support.js"

const decodePage = decode(BotConversationPage)

const conversation = async (running: Running, sessionId: string, query = "") =>
  decodePage(
    (await jsonRequest(running.server, `/v1/sessions/${sessionId}/conversation${query}`)).body
  )

const transcript = async (running: Running, sessionId: string) =>
  (await conversation(running, sessionId)).messages.map((message) => [message.sender, message.text])

const post = (running: Running, path: string, body: Record<string, unknown>) =>
  jsonRequest(running.server, path, { body: JSON.stringify(body), method: "POST" })

const send = (running: Running, sessionId: string, body: Record<string, unknown>) =>
  post(running, `/v1/sessions/${sessionId}/messages`, body)

const prompt = (running: Running, sessionId: string, body: Record<string, unknown>) =>
  post(running, `/v1/sessions/${sessionId}/prompt`, body)

const startBot = async () => {
  const running = await setUp()
  await running.addProject("api-project", "api")
  const bot = decodeBot(
    (await createBot(running, { projectIds: ["api-project"], conversational: true })).body
  )
  return { running, bot }
}

const createChat = async (running: Running, body: Record<string, unknown> = {}) =>
  decode(SessionSummary)(
    (
      await post(running, "/v1/sessions", {
        projectId: "api-project",
        harnessId: "codex",
        title: "Fix login",
        ...body
      })
    ).body
  ).id

const storeImage = async (running: Running) => {
  const stored = await running.services.attachments.put(Buffer.from("fake-png"))
  const file = await run(
    running.services.db.createDiskFile({
      id: randomUUID(),
      name: "shot.png",
      mimeType: "image/png",
      sizeBytes: stored.sizeBytes,
      sha256: stored.sha256,
      kind: "image",
      createdAt: new Date().toISOString()
    })
  )
  return {
    fileId: file.id,
    name: file.name,
    mimeType: file.mimeType,
    sizeBytes: file.sizeBytes,
    kind: file.kind
  }
}

const holdTurn = async (running: Running, sessionId: string) => {
  const before = running.agents.prompts.length
  await prompt(running, sessionId, { text: "prompt until cancelled" })
  await waitFor(() => running.agents.prompts.length > before)
  return running.agents.prompts.at(-1)![0]
}

const cancel = (running: Running, sessionId: string) =>
  post(running, `/v1/sessions/${sessionId}/cancel`, {})

const endTurn = (running: Running, agentSessionId: string, payload: Record<string, unknown>) =>
  running.agents.emit(agentSessionId, {
    kind: "session.updated",
    subjectId: agentSessionId,
    payload: { initiatedBy: "user", turnId: "turn-1", turnState: "ended", ...payload }
  })

const reports = (running: Running) =>
  running.agents.prompts.flatMap(([, input]) =>
    typeof input === "string" && input.startsWith("<codevisor-event") ? [input] : []
  )

describe("bot conversation edges", () => {
  it("pages the conversation and falls back to defaults for unreadable paging", async () => {
    const { running, bot } = await startBot()
    await send(running, bot.sessionId, { text: "one" })
    await send(running, bot.sessionId, { text: "two" })

    const latest = await conversation(running, bot.sessionId, "?limit=1")
    const older = await conversation(
      running,
      bot.sessionId,
      `?limit=1&before=${latest.messages[0]!.sequence}`
    )
    const unreadable = await conversation(running, bot.sessionId, "?limit=lots&before=soon")

    expect(latest).toMatchObject({ hasMore: true, messages: [{ text: "two" }] })
    expect(older).toMatchObject({ hasMore: false, messages: [{ text: "one" }] })
    expect(unreadable.messages.map((message) => message.text)).toEqual(["one", "two"])
  })

  it("refuses messages it cannot deliver and renames attached files on request", async () => {
    const { running, bot } = await startBot()
    const file = join(bot.rootPath, "notes.txt")
    writeFileSync(file, "release notes")

    const empty = await send(running, bot.sessionId, { text: "  " })
    const relative = await send(running, bot.sessionId, {
      text: "here",
      attachments: [{ path: "notes.txt" }]
    })
    const absent = await send(running, bot.sessionId, {
      text: "here",
      attachments: [{ path: join(bot.rootPath, "absent.txt") }]
    })
    const renamed = await send(running, bot.sessionId, {
      text: "",
      attachments: [{ path: file, name: "Release notes.txt" }]
    })

    expect([empty.status, relative.status, absent.status, renamed.status]).toEqual([
      422, 422, 422, 200
    ])
    expect(JSON.stringify(absent.body)).toContain("Could not attach")
    expect((await conversation(running, bot.sessionId)).messages).toMatchObject([
      { sender: "bot", text: "", attachments: [{ name: "Release notes.txt" }] }
    ])
  })

  it("tells the user why the bot couldn't reply, and leaves other chats alone", async () => {
    const { running, bot } = await startBot()
    const chat = await createChat(running)

    await prompt(running, bot.sessionId, { text: "prompt fails" })
    await prompt(running, chat, { text: "prompt fails" })

    await waitFor(async () => (await transcript(running, bot.sessionId)).length === 2)
    expect(await transcript(running, bot.sessionId)).toEqual([
      ["user", "prompt fails"],
      ["notice", "Couldn't reply: prompt failed"]
    ])
  })

  it("posts a stopped turn's reason and stays quiet when the turn had nothing to say", async () => {
    const { running, bot } = await startBot()
    const agentSessionId = await holdTurn(running, bot.sessionId)

    await endTurn(running, agentSessionId, { stopReason: "end_turn" })
    await endTurn(running, agentSessionId, {
      stopReason: "refusal",
      stopKind: "usageLimit",
      stopDetail: "You've hit your usage limit"
    })

    await waitFor(async () => (await transcript(running, bot.sessionId)).length === 2)
    expect(await transcript(running, bot.sessionId)).toEqual([
      ["user", "prompt until cancelled"],
      ["notice", "You've hit your usage limit"]
    ])
    await cancel(running, bot.sessionId)
  })

  it("falls back to the final reply's attachments when the bot never sent a message", async () => {
    const { running, bot } = await startBot()
    const image = await storeImage(running)
    const agentSessionId = await holdTurn(running, bot.sessionId)

    await running.agents.emit(agentSessionId, {
      kind: "session.output",
      subjectId: agentSessionId,
      payload: {
        sessionUpdate: "agent_message_chunk",
        messageId: "reply-1",
        content: {
          type: "text",
          text: `Here it is ![shot](https://attachments.codevisor.invalid/${image.fileId})`
        }
      }
    })
    await endTurn(running, agentSessionId, { stopReason: "end_turn" })

    await waitFor(async () => (await transcript(running, bot.sessionId)).length === 2)
    expect((await conversation(running, bot.sessionId)).messages[1]).toMatchObject({
      sender: "bot",
      attachments: [{ fileId: image.fileId }]
    })
    await cancel(running, bot.sessionId)
  })

  it("shows the files a user sends and replays a resent message only once", async () => {
    const { running, bot } = await startBot()
    const image = await storeImage(running)

    await prompt(running, bot.sessionId, {
      text: "what is this",
      attachments: [image],
      messageId: "client-1"
    })
    await waitFor(async () => (await transcript(running, bot.sessionId)).length === 2)
    await prompt(running, bot.sessionId, { text: "what is this", messageId: "client-1" })
    await waitFor(() => running.agents.prompts.length === 2)

    const messages = (await conversation(running, bot.sessionId)).messages
    expect(messages.filter((message) => message.sender === "user")).toMatchObject([
      { id: "client-1", attachments: [{ fileId: image.fileId }] }
    ])
  })

  it("names an agent the bot can't look up only by its id", async () => {
    const { running, bot } = await startBot()

    await prompt(running, bot.sessionId, { text: "done", fromSessionId: "gone-agent" })

    await waitFor(() => running.agents.prompts.length === 1)
    expect(running.agents.prompts[0]![1]).toBe(
      '<codevisor-event type="session.message" from="gone-agent">\ndone\n</codevisor-event>'
    )
  })

  it("reports a child that ended without a reason or reply, and trims long replies", async () => {
    const { running, bot } = await startBot()
    const quiet = await createChat(running, { parentSessionId: bot.sessionId })
    const chatty = await createChat(running, { parentSessionId: bot.sessionId, title: "Chatty" })
    const quietAgent = await holdTurn(running, quiet)

    await endTurn(running, quietAgent, {})
    await prompt(running, chatty, { text: "x".repeat(4_100) })

    await waitFor(() => reports(running).length >= 2)
    expect(reports(running)).toEqual(
      expect.arrayContaining([
        `<codevisor-event type="session.turn_ended" sessionId="${quiet}" title="Fix login">\n(no final message)\n</codevisor-event>`,
        expect.stringMatching(/title="Chatty" stopReason="end_turn">\nEcho: x+\n…\(truncated\)\n/)
      ])
    )
    await cancel(running, quiet)
  })
})
