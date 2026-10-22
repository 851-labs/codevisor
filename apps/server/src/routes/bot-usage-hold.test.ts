import { BotConversationPage, decode } from "@codevisor/api"
import type { HarnessAuthEvent } from "@codevisor/harness-manager"
import { describe, expect, it } from "vitest"

import {
  jsonRequest,
  listSubjectEvents,
  makeServices,
  run,
  startWithApp,
  waitFor
} from "../test-support.js"
import { createBot, decodeBot, endedTurns, setUpWith } from "./bot-test-support.js"
import { fakeHarnessAuth } from "./harness-auth-test-support.js"
import { field, itemsOf } from "./response-test-support.js"

const accounts = ["personal", "work"]
const weeklyLimit = "You've hit your weekly limit · resets Oct 24 at 7pm (America/Los_Angeles)"

const startServerWithAccounts = async () => {
  const { agents, services } = await makeServices("server-a")
  for (const id of accounts) {
    await run(
      services.db.saveHarnessAccount({
        id,
        harnessId: "codex",
        profileKind: "managed",
        profileKey: id,
        label: id,
        authState: "authenticated",
        canLogin: true,
        canLogout: true
      })
    )
  }
  const listeners: Array<(event: HarnessAuthEvent) => void> = []
  const auth = fakeHarnessAuth({
    accountContext: async (id) => ({ id, profileKind: "managed" }),
    activeAccountContext: async () => ({ id: "personal", profileKind: "managed" }),
    subscribe: (listener) => {
      listeners.push(listener)
      return () => undefined
    }
  })
  const server = await startWithApp({ ...services, auth })
  const switchAccount = (accountId: string) => {
    for (const listener of listeners) {
      listener({
        kind: "harness.auth.updated",
        subjectId: "codex",
        payload: { activeAccountId: accountId }
      })
    }
  }
  return { agents, server, services, switchAccount }
}

type Running = Awaited<ReturnType<typeof startLimitedBot>>["running"]

const post = (running: Running, path: string, body: Record<string, unknown>) =>
  jsonRequest(running.server, path, { body: JSON.stringify(body), method: "POST" })

const startLimitedBot = async () => {
  const running = await setUpWith(startServerWithAccounts)
  await running.addProject("api-project", "api")
  const bot = decodeBot(
    (await createBot(running, { projectIds: ["api-project"], conversational: true })).body
  )
  await post(running, `/v1/sessions/${bot.sessionId}/prompt`, { text: "Check the release" })
  await waitFor(() => endedTurns(running, bot.sessionId) === 1)
  const agentSessionId = running.agents.prompts[0]![0]
  await stopAtLimit(running, agentSessionId, weeklyLimit)
  await waitFor(
    async () => (await run(running.services.db.getAutoResume(bot.sessionId)))?.state === "waiting"
  )
  return { running, sessionId: bot.sessionId, agentSessionId }
}

const stopAtLimit = (running: Running, agentSessionId: string, stopDetail: string) =>
  running.agents.emit(agentSessionId, {
    kind: "session.updated",
    subjectId: agentSessionId,
    payload: {
      initiatedBy: "user",
      turnId: "limited",
      turnState: "ended",
      stopReason: "end_turn",
      stopKind: "usageLimit",
      stopDetail,
      resetsAt: "2099-01-01T00:00:00.000Z"
    }
  })

const wakeUp = async (running: Running, sessionId: string, from: string, queued: number) => {
  await post(running, `/v1/sessions/${sessionId}/prompt`, { text: from, fromSessionId: from })
  await waitFor(() => heldQueueLengths(running, sessionId).includes(queued))
}

const heldQueueLengths = (running: Running, sessionId: string) =>
  listSubjectEvents(running.services, sessionId).flatMap((event) => {
    if (event.kind !== "session.queue.updated") return []
    return [itemsOf(field(event.payload, "queue")).length]
  })

const wakeUpEvent = (from: string) =>
  `<codevisor-event type="session.message" from="${from}">\n${from}\n</codevisor-event>`

const promptTexts = (running: Running) =>
  running.agents.prompts.map(([, input]) => (typeof input === "string" ? input : input.text))

const queueDrained = async (running: Running, sessionId: string) =>
  (await run(running.services.db.listPromptQueue(sessionId))).length === 0 &&
  (await run(running.services.db.listProcessingPromptQueue(sessionId))).length === 0

const conversation = async (running: Running, sessionId: string) =>
  decode(BotConversationPage)(
    (await jsonRequest(running.server, `/v1/sessions/${sessionId}/conversation`)).body
  ).messages.map((message) => [message.sender, message.text])

describe("bots stopped at a usage limit", () => {
  it("posts a repeated limit notice once, and a different or later one again", async () => {
    const { running, sessionId, agentSessionId } = await startLimitedBot()

    await stopAtLimit(running, agentSessionId, weeklyLimit)
    await stopAtLimit(running, agentSessionId, weeklyLimit)
    await stopAtLimit(running, agentSessionId, "You've hit your 5-hour limit")
    await waitFor(async () => (await conversation(running, sessionId)).length === 3)
    await post(running, `/v1/sessions/${sessionId}/messages`, { text: "Still here" })
    await stopAtLimit(running, agentSessionId, "You've hit your 5-hour limit")

    await waitFor(async () => (await conversation(running, sessionId)).length === 5)
    expect(await conversation(running, sessionId)).toEqual([
      ["user", "Check the release"],
      ["notice", weeklyLimit],
      ["notice", "You've hit your 5-hour limit"],
      ["bot", "Still here"],
      ["notice", "You've hit your 5-hour limit"]
    ])
  })

  it("holds wake-ups until the limit resets, then delivers them together in order", async () => {
    const { running, sessionId } = await startLimitedBot()

    await wakeUp(running, sessionId, "agent-a", 1)
    await wakeUp(running, sessionId, "agent-b", 2)
    await wakeUp(running, sessionId, "agent-c", 3)
    expect(promptTexts(running)).toHaveLength(1)
    running.switchAccount("work")

    await waitFor(() => queueDrained(running, sessionId))
    const [, released] = promptTexts(running)
    expect(promptTexts(running)).toHaveLength(2)
    expect(released).toMatch(
      new RegExp(
        `^${[wakeUpEvent("agent-a"), wakeUpEvent("agent-b"), wakeUpEvent("agent-c"), ""].join("\n\n")}<codevisor-event type="session.usage_limit_reset"`
      )
    )
  })

  it("delivers held wake-ups when the user declines the auto-resume", async () => {
    const { running, sessionId } = await startLimitedBot()
    await wakeUp(running, sessionId, "agent-a", 1)

    const declined = await jsonRequest(running.server, `/v1/sessions/${sessionId}/auto-resume`, {
      method: "DELETE"
    })

    expect(declined.status).toBe(204)
    await waitFor(() => queueDrained(running, sessionId))
    expect(promptTexts(running)).toEqual(["Check the release", wakeUpEvent("agent-a")])
  })

  it("lets the user's own message through, after the wake-ups held before it", async () => {
    const { running, sessionId } = await startLimitedBot()
    await wakeUp(running, sessionId, "agent-a", 1)

    await post(running, `/v1/sessions/${sessionId}/prompt`, { text: "Are you there?" })

    await waitFor(() => queueDrained(running, sessionId))
    expect(promptTexts(running)).toHaveLength(3)
    expect(promptTexts(running).slice(0, 2)).toEqual(["Check the release", wakeUpEvent("agent-a")])
    expect(promptTexts(running)[2]).toContain("Are you there?")
  })
})
