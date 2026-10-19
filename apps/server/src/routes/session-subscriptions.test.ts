import {
  decode,
  SessionSubscription,
  SessionSubscriptionList,
  SessionSummary,
  TranscriptPage
} from "@codevisor/api"
import { describe, expect, it } from "vitest"

import { archiveSessionViaWorkspace, jsonRequest, waitFor } from "../test-support.js"
import { setUp, type Running } from "./bot-test-support.js"

const post = (running: Running, path: string, body: Record<string, unknown>) =>
  jsonRequest(running.server, path, { body: JSON.stringify(body), method: "POST" })

const startServer = async () => {
  const running = await setUp()
  await running.addProject("api-project", "api")
  return running
}

const createChat = async (running: Running, title: string, extra: Record<string, unknown> = {}) =>
  decode(SessionSummary)(
    (
      await post(running, "/v1/sessions", {
        projectId: "api-project",
        harnessId: "codex",
        title,
        ...extra
      })
    ).body
  ).id

const subscribe = async (running: Running, subscriberId: string, body: Record<string, unknown>) =>
  decode(SessionSubscription)(
    (await post(running, `/v1/sessions/${subscriberId}/subscriptions`, body)).body
  )

const prompt = (running: Running, sessionId: string, text: string) =>
  post(running, `/v1/sessions/${sessionId}/prompt`, { text })

const eventPrompts = (running: Running) =>
  running.agents.prompts.flatMap(([, input]) =>
    typeof input === "string" && input.startsWith("<codevisor-event") ? [{ input }] : []
  )

const holdTurn = async (running: Running, sessionId: string) => {
  const before = running.agents.prompts.length
  await prompt(running, sessionId, "prompt until cancelled")
  await waitFor(() => running.agents.prompts.length > before)
}

const finishTurn = async (running: Running, sessionId: string) => {
  const before = running.agents.prompts.length
  await prompt(running, sessionId, "work")
  await waitFor(() => running.agents.prompts.length > before)
}

const transcript = async (running: Running, sessionId: string) =>
  decode(TranscriptPage)(
    (await jsonRequest(running.server, `/v1/sessions/${sessionId}/transcript`)).body
  )

const hiddenEvents = async (running: Running, sessionId: string) =>
  (await transcript(running, sessionId)).items
    .filter((item) => item.origin === "event")
    .map((item) => item.text)

describe("session event subscriptions", () => {
  it("wakes an idle subscriber with a hidden one-shot event and then forgets the subscription", async () => {
    const running = await startServer()
    const watcher = await createChat(running, "Watcher")
    const worker = await createChat(running, "Fix login", { parentSessionId: watcher })
    const subscription = await subscribe(running, watcher, { targetSessionId: worker, once: true })

    await finishTurn(running, worker)
    await waitFor(() => eventPrompts(running).length === 1)

    const delivered = eventPrompts(running)[0]!.input
    expect(delivered).toContain(
      `<codevisor-event type="session.turn_ended" sessionId="${worker}" title="Fix login"`
    )
    expect(delivered).toContain(`subscriptionId="${subscription.id}"`)
    const held = decode(SessionSubscriptionList)(
      (await jsonRequest(running.server, `/v1/sessions/${watcher}/subscriptions`)).body
    )
    expect(held.subscriptions).toEqual([])
  })

  it("holds events for a busy subscriber and delivers them together when its turn ends", async () => {
    const running = await startServer()
    const watcher = await createChat(running, "Watcher")
    const first = await createChat(running, "First")
    const second = await createChat(running, "Second")
    await subscribe(running, watcher, { targetSessionId: first })
    await subscribe(running, watcher, { targetSessionId: second })
    await holdTurn(running, watcher)

    await finishTurn(running, first)
    await finishTurn(running, second)
    await post(running, `/v1/sessions/${watcher}/cancel`, {})
    await waitFor(() => eventPrompts(running).length > 0)

    const delivered = await hiddenEvents(running, watcher)
    expect(eventPrompts(running)).toHaveLength(1)
    expect(delivered).toHaveLength(1)
    expect(delivered[0]).toContain(`sessionId="${first}" title="First"`)
    expect(delivered[0]).toContain(`sessionId="${second}" title="Second"`)
  })

  it("records delivered events as hidden transcript items, unlike prompts the user typed", async () => {
    const running = await startServer()
    const watcher = await createChat(running, "Watcher")
    const worker = await createChat(running, "Fix login")
    await subscribe(running, watcher, { targetSessionId: worker })
    await finishTurn(running, watcher)

    await finishTurn(running, worker)
    await waitFor(async () =>
      (await transcript(running, watcher)).items.some((item) => item.origin === "event")
    )

    const users = (await transcript(running, watcher)).items.filter((item) => item.role === "user")
    expect(users.map((item) => [item.text.startsWith("<codevisor-event"), item.origin])).toEqual([
      [false, undefined],
      [true, "event"]
    ])
  })

  it("skips archived subscribers", async () => {
    const running = await startServer()
    const archived = await createChat(running, "Archived")
    const live = await createChat(running, "Live")
    const worker = await createChat(running, "Fix login")
    await subscribe(running, archived, { targetSessionId: worker })
    await subscribe(running, live, { targetSessionId: worker })
    await archiveSessionViaWorkspace(running.services, "api-project", archived)

    await finishTurn(running, worker)
    await waitFor(async () => (await hiddenEvents(running, live)).length === 1)

    expect(await hiddenEvents(running, archived)).toEqual([])
  })

  it("tells subscribers when a target starts waiting on a question", async () => {
    const running = await startServer()
    const watcher = await createChat(running, "Watcher")
    const worker = await createChat(running, "Fix login")
    await subscribe(running, watcher, { targetSessionId: worker, events: ["waiting_for_user"] })
    await holdTurn(running, worker)
    const workerAgent = running.agents.prompts.at(-1)![0]

    await running.agents.emit(workerAgent, {
      kind: "session.output",
      subjectId: workerAgent,
      payload: {
        sessionUpdate: "question",
        questionId: "q1",
        questions: [
          { id: "go", question: "Ship it?", options: [{ label: "Yes" }], allowsOther: false }
        ]
      }
    })
    await waitFor(async () => (await hiddenEvents(running, watcher)).length === 1)

    const [event] = await hiddenEvents(running, watcher)
    expect(event).toContain(
      `<codevisor-event type="session.waiting_for_user" sessionId="${worker}" title="Fix login" kind="question"`
    )
    expect(event).toContain('"questionId":"q1"')
    expect(event).toContain("Answer it with sessions.question_answer.")
    await post(running, `/v1/sessions/${worker}/cancel`, {})
  })

  it("reports a target's error to subscribers that asked for errors", async () => {
    const running = await startServer()
    const watcher = await createChat(running, "Watcher")
    const worker = await createChat(running, "Fix login")
    await subscribe(running, watcher, { targetSessionId: worker, events: ["errored"] })

    await prompt(running, worker, "prompt fails")
    await waitFor(() => eventPrompts(running).length === 1)

    expect(eventPrompts(running)[0]!.input).toContain(
      `<codevisor-event type="session.errored" sessionId="${worker}" title="Fix login"`
    )
    expect(eventPrompts(running)[0]!.input).toContain("prompt failed")
  })

  it("doesn't bounce a turn back to the session whose event started it", async () => {
    const running = await startServer()
    const left = await createChat(running, "Left")
    const right = await createChat(running, "Right")
    const observer = await createChat(running, "Observer")
    await subscribe(running, left, { targetSessionId: right })
    await subscribe(running, right, { targetSessionId: left })
    await subscribe(running, observer, { targetSessionId: left })

    await finishTurn(running, right)
    await waitFor(async () => (await hiddenEvents(running, observer)).length === 1)

    expect(await hiddenEvents(running, left)).toEqual([expect.stringContaining('title="Right"')])
    expect(await hiddenEvents(running, observer)).toEqual([expect.stringContaining('title="Left"')])
    expect(await hiddenEvents(running, right)).toEqual([])
  })

  it("lists, refuses, and removes subscriptions", async () => {
    const running = await startServer()
    const watcher = await createChat(running, "Watcher")
    const worker = await createChat(running, "Fix login")

    const self = await post(running, `/v1/sessions/${watcher}/subscriptions`, {
      targetSessionId: watcher
    })
    const missing = await post(running, `/v1/sessions/${watcher}/subscriptions`, {
      targetSessionId: "no-such-session"
    })
    const created = await subscribe(running, watcher, { targetSessionId: worker })
    const listed = decode(SessionSubscriptionList)(
      (await jsonRequest(running.server, `/v1/sessions/${watcher}/subscriptions`)).body
    )
    const removed = await jsonRequest(
      running.server,
      `/v1/sessions/${watcher}/subscriptions/${created.id}`,
      { method: "DELETE" }
    )
    const again = await jsonRequest(
      running.server,
      `/v1/sessions/${watcher}/subscriptions/${created.id}`,
      { method: "DELETE" }
    )

    expect([self.status, missing.status, removed.status, again.status]).toEqual([
      422, 404, 204, 404
    ])
    expect(listed.subscriptions).toEqual([
      expect.objectContaining({
        id: created.id,
        targetSessionId: worker,
        events: ["turn_ended", "waiting_for_user", "errored"],
        once: false
      })
    ])
  })

  it("explains that unknown jobs are gone", async () => {
    const running = await startServer()

    const missing = await jsonRequest(running.server, "/v1/jobs/feedface01")

    expect(missing.status).toBe(404)
    expect(JSON.stringify(missing.body)).toContain("don't survive a server restart")
  })
})
