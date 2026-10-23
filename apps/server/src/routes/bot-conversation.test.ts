import { readFileSync, writeFileSync } from "node:fs"
import { join } from "node:path"

import { BotConversationPage, decode, SessionSummary } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import { jsonRequest, listSubjectEvents, run, waitFor } from "../test-support.js"
import { createBot, decodeBot, endedTurns, setUp, type Running } from "./bot-test-support.js"

const decodePage = decode(BotConversationPage)

const conversation = async (running: Running, sessionId: string) =>
  decodePage((await jsonRequest(running.server, `/v1/sessions/${sessionId}/conversation`)).body)

const transcript = async (running: Running, sessionId: string) =>
  (await conversation(running, sessionId)).messages.map((message) => [message.sender, message.text])

const prompt = (running: Running, sessionId: string, text: string, messageId?: string) =>
  jsonRequest(running.server, `/v1/sessions/${sessionId}/prompt`, {
    body: JSON.stringify({ text, ...(messageId === undefined ? {} : { messageId }) }),
    method: "POST"
  })

const startBot = async () => {
  const running = await setUp()
  await running.addProject("api-project", "api")
  const bot = decodeBot(
    (await createBot(running, { projectIds: ["api-project"], conversational: true })).body
  )
  return { running, bot }
}

describe("bot conversations", () => {
  it("records the user's message at once and posts none of the bot's own replies", async () => {
    const { running, bot } = await startBot()
    expect(bot.conversational).toBe(true)
    expect(readFileSync(join(bot.rootPath, "AGENTS.md"), "utf8")).toContain(
      "`machines.current.tools.codevisor.messages.send`"
    )

    await prompt(running, bot.sessionId, "hello", "client-1")

    await waitFor(() => endedTurns(running, bot.sessionId) === 1)
    expect(await transcript(running, bot.sessionId)).toEqual([["user", "hello"]])
    const [sent] = (await conversation(running, bot.sessionId)).messages
    expect(sent?.id).toBe("client-1")
    expect(
      listSubjectEvents(running.services, bot.sessionId).filter(
        (event) => event.kind === "bot.message"
      )
    ).toHaveLength(1)
  })

  it("takes a retried send once when the first attempt already landed", async () => {
    const { running, bot } = await startBot()
    const send = () =>
      jsonRequest(running.server, `/v1/sessions/${bot.sessionId}/prompt`, {
        body: JSON.stringify({ text: "hello", messageId: "client-1", clientActionId: "client-1" }),
        method: "POST"
      })

    await send()
    await waitFor(() => endedTurns(running, bot.sessionId) === 1)
    const retried = await send()

    expect(retried.status).toBe(202)
    expect(running.agents.prompts).toHaveLength(1)
    expect(await transcript(running, bot.sessionId)).toEqual([["user", "hello"]])
  })

  it("posts exactly the messages the bot sends", async () => {
    const { running, bot } = await startBot()

    await prompt(running, bot.sessionId, "slow prompt")
    await waitFor(() => running.agents.prompts.length === 1)
    for (const text of ["On it", "Done"]) {
      await jsonRequest(running.server, `/v1/sessions/${bot.sessionId}/messages`, {
        body: JSON.stringify({ text }),
        method: "POST"
      })
    }
    running.agents.releasePrompt()
    await waitFor(() => endedTurns(running, bot.sessionId) === 1)
    await prompt(running, bot.sessionId, "hello")

    await waitFor(() => endedTurns(running, bot.sessionId) === 2)
    expect(await transcript(running, bot.sessionId)).toEqual([
      ["user", "slow prompt"],
      ["bot", "On it"],
      ["bot", "Done"],
      ["user", "hello"]
    ])
  })

  it("keeps the bot's name when its harness titles the chat", async () => {
    const { running, bot } = await startBot()
    await prompt(running, bot.sessionId, "hello")
    await waitFor(() => running.agents.prompts.length === 1)
    const agentSessionId = running.agents.prompts[0]![0]

    await running.agents.emit(agentSessionId, {
      kind: "session.updated",
      subjectId: agentSessionId,
      payload: { sessionUpdate: "session_info_update", title: "Repo contents" }
    })

    expect((await run(running.services.db.getSessionSummary(bot.sessionId))).title).toBe(
      "Release Helper"
    )
  })

  it("lets only the bot's own chat send messages, with files attached by path", async () => {
    const { running, bot } = await startBot()
    const file = join(bot.rootPath, "notes.txt")
    writeFileSync(file, "release notes")

    const sent = await jsonRequest(running.server, `/v1/sessions/${bot.sessionId}/messages`, {
      body: JSON.stringify({ text: "Here you go", attachments: [{ path: file }] }),
      method: "POST"
    })
    const child = await jsonRequest(running.server, "/v1/sessions", {
      body: JSON.stringify({ projectId: "api-project", harnessId: "codex", title: "Child" }),
      method: "POST"
    })
    const childId = decode(SessionSummary)(child.body).id
    const refused = await jsonRequest(running.server, `/v1/sessions/${childId}/messages`, {
      body: JSON.stringify({ text: "hi" }),
      method: "POST"
    })

    expect(sent.status).toBe(200)
    expect(refused.status).toBe(403)
    const [message] = (await conversation(running, bot.sessionId)).messages
    expect(message).toMatchObject({
      sender: "bot",
      text: "Here you go",
      attachments: [{ name: "notes.txt", mimeType: "text/plain" }]
    })
  })

  it("steers messages into a running turn instead of queueing them", async () => {
    const { running, bot } = await startBot()

    await prompt(running, bot.sessionId, "prompt until cancelled")
    await waitFor(() => running.agents.prompts.length === 1)
    await prompt(running, bot.sessionId, "also do this")

    await waitFor(() => running.agents.steers.length === 1)
    expect(running.agents.steers[0]?.[1]).toBe("also do this")
    expect(await run(running.services.db.listPromptQueue(bot.sessionId))).toEqual([])
    expect(await transcript(running, bot.sessionId)).toEqual([
      ["user", "prompt until cancelled"],
      ["user", "also do this"]
    ])
    expect((await conversation(running, bot.sessionId)).working).toBe(true)

    await jsonRequest(running.server, `/v1/sessions/${bot.sessionId}/cancel`, {
      body: JSON.stringify({}),
      method: "POST"
    })
    await waitFor(async () => !(await conversation(running, bot.sessionId)).working)
    expect(running.agents.prompts).toHaveLength(1)
    expect(await transcript(running, bot.sessionId)).toHaveLength(2)
  })

  it("leaves a bot without conversation mode on the transcript and queue", async () => {
    const running = await setUp()
    await running.addProject("api-project", "api")
    const bot = decodeBot((await createBot(running, { projectIds: ["api-project"] })).body)

    await prompt(running, bot.sessionId, "prompt until cancelled")
    await waitFor(() => running.agents.prompts.length === 1)
    await jsonRequest(running.server, `/v1/sessions/${bot.sessionId}/prompt`, {
      body: JSON.stringify({ text: "also do this", delivery: "queue" }),
      method: "POST"
    })
    const sent = await jsonRequest(running.server, `/v1/sessions/${bot.sessionId}/messages`, {
      body: JSON.stringify({ text: "hi" }),
      method: "POST"
    })

    expect(bot.conversational).toBe(false)
    expect(sent.status).toBe(403)
    await waitFor(
      async () => (await run(running.services.db.listPromptQueue(bot.sessionId))).length === 1
    )
    expect(await transcript(running, bot.sessionId)).toEqual([])
  })

  it("hands the bot a message from another agent without showing it in the conversation", async () => {
    const { running, bot } = await startBot()
    const agent = decode(SessionSummary)(
      (
        await jsonRequest(running.server, "/v1/sessions", {
          body: JSON.stringify({
            projectId: "api-project",
            harnessId: "codex",
            title: "Fix login"
          }),
          method: "POST"
        })
      ).body
    )

    await jsonRequest(running.server, `/v1/sessions/${bot.sessionId}/prompt`, {
      body: JSON.stringify({ text: "login is fixed", fromSessionId: agent.id }),
      method: "POST"
    })

    await waitFor(() =>
      running.agents.prompts.some(
        ([, input]) => typeof input === "string" && input.includes("login is fixed")
      )
    )
    const delivered = running.agents.prompts.find(
      ([, input]) => typeof input === "string" && input.includes("login is fixed")
    )?.[1]
    expect(delivered).toBe(
      `<codevisor-event type="session.message" from="${agent.id}" title="Fix login">\nlogin is fixed\n</codevisor-event>`
    )
    await waitFor(async () => !(await conversation(running, bot.sessionId)).working)
    expect(await transcript(running, bot.sessionId)).toEqual([])
  })

  it("tells the bot when an agent it started finishes, without showing the user", async () => {
    const { running, bot } = await startBot()
    const child = await jsonRequest(running.server, "/v1/sessions", {
      body: JSON.stringify({
        projectId: "api-project",
        harnessId: "codex",
        title: "Fix login",
        parentSessionId: bot.sessionId
      }),
      method: "POST"
    })
    const childId = decode(SessionSummary)(child.body).id

    await prompt(running, childId, "fix it")

    await waitFor(() =>
      running.agents.prompts.some(
        ([, input]) => typeof input === "string" && input.startsWith("<codevisor-event")
      )
    )
    const report = running.agents.prompts.find(
      ([, input]) => typeof input === "string" && input.startsWith("<codevisor-event")
    )?.[1]
    expect(report).toContain(`agentId="${childId}" title="Fix login" stopReason="end_turn"`)
    expect(report).toContain("Echo: fix it")
    await waitFor(() => endedTurns(running, bot.sessionId) === 1)
    expect(await transcript(running, bot.sessionId)).toEqual([])
  })
})
