import { readFileSync, writeFileSync } from "node:fs"
import { join } from "node:path"

import { BotConversationPage, decode, SessionSummary } from "@codevisor/api"
import { Effect } from "effect"
import { describe, expect, it, vi } from "vitest"

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

const readsSteersAtNextStep = ({ agents }: Running): ReadonlyArray<string> => {
  const interrupted: Array<string> = []
  const load = agents.loadAgentSession.bind(agents)
  vi.spyOn(agents, "loadAgentSession").mockImplementation((...args) =>
    Effect.map(load(...args), (metadata) => ({ ...metadata, steersAtNextStep: true }))
  )
  Object.assign(agents, {
    interruptStep: (id: string) =>
      Effect.sync(() => {
        interrupted.push(id)
        return true
      })
  })
  return interrupted
}

const startBot = async () => {
  const running = await setUp()
  await running.addProject("api-project", "api")
  const bot = decodeBot((await createBot(running, { projectIds: ["api-project"] })).body)
  return { running, bot }
}

describe("bot conversations", () => {
  it("records the user's message at once and posts none of the bot's own replies", async () => {
    const { running, bot } = await startBot()
    expect(readFileSync(join(bot.rootPath, "AGENTS.md"), "utf8")).toContain("`messages.send`")

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

  it("interrupts the running step at once so the bot reads a message sent mid-turn straight away", async () => {
    const { running, bot } = await startBot()
    const interrupted = readsSteersAtNextStep(running)

    await prompt(running, bot.sessionId, "prompt until cancelled")
    await waitFor(() => running.agents.prompts.length === 1)
    await prompt(running, bot.sessionId, "also do this")

    await waitFor(() => interrupted.length === 1)
    expect(interrupted).toEqual([running.agents.prompts[0]![0]])
    expect(running.agents.cancellations).toEqual([])
    expect(await run(running.services.db.listVisiblePromptQueue(bot.sessionId))).toEqual([])
    expect(await transcript(running, bot.sessionId)).toEqual([
      ["user", "prompt until cancelled"],
      ["user", "also do this"]
    ])
  })

  it("refuses an agent's message aimed at a bot's chat and names the way to reach it", async () => {
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
    const send = (sentByAgentId: string) =>
      jsonRequest(running.server, `/v1/sessions/${bot.sessionId}/prompt`, {
        body: JSON.stringify({ text: "login is fixed", sentByAgentId }),
        method: "POST"
      })

    const refused = await send(agent.id)

    expect([refused.status, refused.body]).toEqual([
      409,
      {
        error: `Release Helper is a bot, not an agent. Message it with bots.message({ botId: "${bot.id}", text })`
      }
    ])
    expect(running.agents.prompts).toEqual([])
    expect((await send(bot.sessionId)).status).toBe(202)
    await waitFor(() => running.agents.prompts.length === 1)
    expect(await transcript(running, bot.sessionId)).toEqual([["user", "login is fixed"]])
  })

  it("tells the bot when an agent it started finishes, without showing the user", async () => {
    const { running, bot } = await startBot()
    const child = await jsonRequest(running.server, "/v1/sessions", {
      body: JSON.stringify({
        projectId: "api-project",
        harnessId: "codex",
        title: "Fix login",
        createdByAgentId: bot.sessionId
      }),
      method: "POST"
    })
    const childId = decode(SessionSummary)(child.body).id

    await jsonRequest(running.server, `/v1/sessions/${childId}/prompt`, {
      body: JSON.stringify({ text: "fix it", sentByAgentId: bot.sessionId }),
      method: "POST"
    })

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
