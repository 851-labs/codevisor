import { randomUUID } from "node:crypto"
import { appendFileSync, readFileSync } from "node:fs"
import { join } from "node:path"

import { BotConversationPage, decode, SessionSummary, type Bot } from "@codevisor/api"
import { Schema } from "effect"
import { describe, expect, it } from "vitest"

import { jsonRequest, run, waitFor } from "../test-support.js"
import { HANDOFF_OPENING } from "./bot-handoff-text.js"
import { createBot, decodeBot, setUp, type Running } from "./bot-test-support.js"

const post = (running: Running, path: string, body: Record<string, unknown>) =>
  jsonRequest(running.server, path, { body: JSON.stringify(body), method: "POST" })

const startBot = async () => {
  const running = await setUp()
  await running.addProject("api-project", "api")
  const source = decodeBot((await createBot(running, { projectIds: ["api-project"] })).body)
  return { running, source }
}

const fork = async (running: Running, source: Bot, moveAgents: boolean) => {
  const response = await post(running, `/v1/bots/${source.id}/fork`, {
    name: "Release Helper Fork",
    harnessId: "codex",
    moveAgents
  })
  expect(response.status).toBe(201)
  return decodeBot(response.body)
}

const say = (running: Running, bot: Bot, sender: "user" | "bot", text: string) =>
  run(running.services.db.appendBotMessage(bot.sessionId, { sender, text }))

const conversation = async (running: Running, bot: Bot) =>
  decode(BotConversationPage)(
    (await jsonRequest(running.server, `/v1/sessions/${bot.sessionId}/conversation`)).body
  ).messages.map((message) => [message.sender, message.text])

const instructions = (bot: Bot) => readFileSync(join(bot.rootPath, "AGENTS.md"), "utf8")

const startAgent = async (running: Running, creator: Bot) =>
  decode(SessionSummary)(
    (
      await post(running, "/v1/sessions", {
        projectId: "api-project",
        harnessId: "codex",
        title: "Fix the flaky test",
        workspaceId: randomUUID(),
        createdByAgentId: creator.sessionId
      })
    ).body
  )

const creatorOf = async (running: Running, sessionId: string) => {
  const detail = (await jsonRequest(running.server, `/v1/sessions/${sessionId}`)).body
  return decode(Schema.Struct({ session: SessionSummary }))(detail).session.createdByAgentId
}

const queuedTexts = async (running: Running, bot: Bot) =>
  (await run(running.services.db.listPromptQueue(bot.sessionId))).map((item) => item.text)

const promptTexts = (running: Running) =>
  running.agents.prompts.map(([, input]) => (typeof input === "string" ? input : input.text))

const queueDrained = async (running: Running, bot: Bot) =>
  (await run(running.services.db.listPromptQueue(bot.sessionId))).length === 0 &&
  (await run(running.services.db.listProcessingPromptQueue(bot.sessionId))).length === 0

describe("forking a bot", () => {
  it("makes a new bot on the same projects with the source's notes and conversation", async () => {
    const { running, source } = await startBot()
    appendFileSync(join(source.rootPath, "AGENTS.md"), "\nPrefer squash merges.\n")
    await say(running, source, "user", "Ship the release")
    await say(running, source, "bot", "Shipping it now.")

    const forked = await fork(running, source, false)

    expect(forked.id).not.toBe(source.id)
    expect(forked.name).toBe("Release Helper Fork")
    expect(forked.projects.map((project) => project.projectId)).toEqual(["api-project"])
    expect(forked.projects[0]?.branch).not.toBe(source.projects[0]?.branch)
    expect(instructions(forked)).toContain("# Release Helper Fork")
    expect(instructions(forked)).toContain("Prefer squash merges.")
    expect(await conversation(running, forked)).toEqual([
      ["user", "Ship the release"],
      ["bot", "Shipping it now."]
    ])
  })

  it("holds the handoff until the first message, then delivers both in one turn", async () => {
    const { running, source } = await startBot()
    await say(running, source, "user", "Ship the release")

    const forked = await fork(running, source, false)
    const [held] = await queuedTexts(running, forked)
    await post(running, `/v1/sessions/${forked.sessionId}/prompt`, { text: "Are you there?" })
    await waitFor(() => queueDrained(running, forked))

    expect(held).toMatch(new RegExp(`^${HANDOFF_OPENING}`))
    expect(held).toContain("Ship the release")
    expect(promptTexts(running)).toHaveLength(1)
    expect(promptTexts(running)[0]).toMatch(new RegExp(`^${HANDOFF_OPENING}`))
    expect(promptTexts(running)[0]).toContain("Are you there?")
  })

  it("by default keeps the source's name and mascot and moves its agents, listing them in the handoff", async () => {
    const { running, source } = await startBot()
    const agent = await startAgent(running, source)

    const response = await post(running, `/v1/bots/${source.id}/fork`, { harnessId: "codex" })
    const forked = decodeBot(response.body)

    expect(response.status).toBe(201)
    expect(forked.name).toBe("Release Helper (fork)")
    expect(forked.mascot).toEqual(source.mascot)
    expect(await creatorOf(running, agent.id)).toBe(forked.sessionId)
    expect((await queuedTexts(running, forked))[0]).toContain(
      `Fix the flaky test (agentId \`${agent.id}\`)`
    )
  })

  it("leaves the source's agents with it when asked to", async () => {
    const { running, source } = await startBot()
    const agent = await startAgent(running, source)

    const forked = await fork(running, source, false)

    expect(await creatorOf(running, agent.id)).toBe(source.sessionId)
    expect((await queuedTexts(running, forked))[0]).not.toContain(agent.id)
  })

  it("refuses to fork an archived bot", async () => {
    const { running, source } = await startBot()
    await jsonRequest(running.server, `/v1/bots/${source.id}`, {
      body: JSON.stringify({ isArchived: true }),
      method: "PATCH"
    })

    const response = await post(running, `/v1/bots/${source.id}/fork`, {
      name: "Release Helper Fork",
      harnessId: "codex",
      moveAgents: false
    })

    expect(response.status).toBe(409)
  })
})
