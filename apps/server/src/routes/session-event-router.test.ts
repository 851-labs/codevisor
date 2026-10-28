import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { EventEnvelope } from "@codevisor/api"
import { afterEach, beforeEach, describe, expect, it, onTestFinished, vi } from "vitest"

import { appendAndPublish, makeEventFanout } from "../server-context.js"
import { idleRouteState, makeServices, run, tempDirs, waitFor } from "../test-support.js"
import { finalAssistantText, makeSessionEventRouter } from "./session-event-router.js"
import { HELD_TURN_END_GRACE_MS, HELD_TURN_END_MAX_MS } from "./turn-end-holds.js"

const setUpRouter = async () => {
  const { agents, services } = await makeServices("server-a")
  const fanout = await run(makeEventFanout)
  const routeState = idleRouteState()
  const router = makeSessionEventRouter(services, fanout, routeState, "server-a", async () => {})
  onTestFinished(fanout.subscribe(router.listener))
  const folder = mkdtempSync(join(tmpdir(), "codevisor-event-router-"))
  tempDirs.push(folder)
  const project = await run(services.db.createProject({ folderPath: folder }))
  const chat = async () =>
    (await run(services.db.createSession({ projectId: project.id, harnessId: "codex" }))).id
  const emit = (
    sessionId: string,
    payload: unknown,
    kind: EventEnvelope["kind"] = "session.updated"
  ) => appendAndPublish(services.db, fanout, kind, sessionId, payload)
  const say = (sessionId: string, role: "user" | "assistant", text: string) =>
    emit(sessionId, { role, text }, "session.output")
  const eventPrompts = () =>
    agents.prompts.flatMap(([, input]) =>
      typeof input === "string" && input.startsWith("<codevisor-event") ? [input] : []
    )
  return { services, routeState, chat, emit, say, eventPrompts }
}

type Router = Awaited<ReturnType<typeof setUpRouter>>

const shell = { id: "task-1", description: "npm test", status: "running", taskType: "shell" }

const turn = async (router: Router, sessionId: string, turnId: string, reply: string) => {
  await router.emit(sessionId, { initiatedBy: "user", turnId, turnState: "started" })
  await router.say(sessionId, "assistant", reply)
  await router.emit(sessionId, {
    initiatedBy: "user",
    stopReason: "end_turn",
    turnId,
    turnState: "ended"
  })
}

describe("held turn ends", () => {
  beforeEach(() => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] })
  })
  afterEach(() => vi.useRealTimers())

  it("reports turns that left background work once, after it drains without a follow-up", async () => {
    const router = await setUpRouter()
    const watcher = await router.chat()
    const worker = await router.chat()
    await run(
      router.services.db.createSessionSubscription({
        subscriberSessionId: watcher,
        targetSessionId: worker,
        events: ["turn_ended"],
        once: false
      })
    )
    await router.emit(worker, { backgroundTasks: [shell] })
    await turn(router, worker, "turn-1", "Started the tests")
    await turn(router, worker, "turn-2", "Still running")

    await router.emit(worker, { backgroundTasks: [] })
    await vi.advanceTimersByTimeAsync(HELD_TURN_END_GRACE_MS - 1)
    expect(router.eventPrompts()).toEqual([])
    await vi.advanceTimersByTimeAsync(1)
    await waitFor(() => router.eventPrompts().length > 0)

    const [delivered, ...rest] = router.eventPrompts()
    expect(rest).toEqual([])
    expect(delivered).toContain(
      `<codevisor-event type="session.turn_ended" agentId="${worker}" title="New Session"`
    )
    expect(delivered).toContain('stopReason="end_turn"')
    expect(delivered).toContain("\nStill running\n")
  })
})

describe("turn ends held by long-lived background work", () => {
  beforeEach(() => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] })
  })
  afterEach(() => vi.useRealTimers())

  const devServer = {
    id: "task-9",
    description: "bun run dev",
    status: "running",
    taskType: "shell"
  }

  it("reports the turn once the hold runs out, and doesn't hold later turns for the same work", async () => {
    const router = await setUpRouter()
    const watcher = await router.chat()
    const worker = await router.chat()
    await run(
      router.services.db.createSessionSubscription({
        subscriberSessionId: watcher,
        targetSessionId: worker,
        events: ["turn_ended"],
        once: false
      })
    )
    await router.emit(worker, { backgroundTasks: [devServer] })
    await turn(router, worker, "turn-1", "PR is up; the dev app is still running")
    expect(router.routeState.heldTurnEnds.has(worker)).toBe(true)

    await vi.advanceTimersByTimeAsync(HELD_TURN_END_MAX_MS - 1)
    expect(router.eventPrompts()).toEqual([])
    await vi.advanceTimersByTimeAsync(1)
    await waitFor(() => router.eventPrompts().length === 1)
    expect(router.eventPrompts()[0]).toContain("\nPR is up; the dev app is still running\n")
    expect(router.routeState.heldTurnEnds.has(worker)).toBe(false)

    await turn(router, worker, "turn-2", "Added the tests")
    await waitFor(() => router.eventPrompts().length === 2)
    expect(router.eventPrompts()[1]).toContain("\nAdded the tests\n")
    expect(router.routeState.heldTurnEnds.has(worker)).toBe(false)
  })

  it("holds a later turn again for background work started since", async () => {
    const router = await setUpRouter()
    const watcher = await router.chat()
    const worker = await router.chat()
    await run(
      router.services.db.createSessionSubscription({
        subscriberSessionId: watcher,
        targetSessionId: worker,
        events: ["turn_ended"],
        once: false
      })
    )
    await router.emit(worker, { backgroundTasks: [devServer] })
    await turn(router, worker, "turn-1", "Dev app is up")
    await vi.advanceTimersByTimeAsync(HELD_TURN_END_MAX_MS)
    await waitFor(() => router.eventPrompts().length === 1)

    await router.emit(worker, { backgroundTasks: [devServer, shell] })
    await turn(router, worker, "turn-2", "Started the tests")

    expect(router.routeState.heldTurnEnds.has(worker)).toBe(true)
    expect(router.eventPrompts()).toHaveLength(1)
  })
})

describe("superseded held turn ends", () => {
  beforeEach(() => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] })
  })
  afterEach(() => vi.useRealTimers())

  it.each([
    { name: "errors", kind: "session.error" as const, payload: { message: "boom" } },
    {
      name: "asks a question",
      kind: "session.attention.updated" as const,
      payload: { actionRequiredKind: "question" }
    }
  ])("never sends a stale turn end after the agent $name", async ({ kind, payload }) => {
    const router = await setUpRouter()
    const watcher = await router.chat()
    const worker = await router.chat()
    await run(
      router.services.db.createSessionSubscription({
        subscriberSessionId: watcher,
        targetSessionId: worker,
        events: ["turn_ended"],
        once: false
      })
    )
    await router.emit(worker, { backgroundTasks: [shell] })
    await turn(router, worker, "turn-1", "Started the tests")
    await router.emit(worker, { backgroundTasks: [] })

    await router.emit(worker, payload, kind)
    await vi.advanceTimersByTimeAsync(HELD_TURN_END_GRACE_MS * 2)
    await turn(router, worker, "turn-2", "Fixed and done")
    await waitFor(() => router.eventPrompts().length > 0)

    expect(router.eventPrompts()).toEqual([expect.stringContaining("\nFixed and done\n")])
  })
})

describe("held turn ends waiting in the outbox", () => {
  beforeEach(() => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] })
  })
  afterEach(() => vi.useRealTimers())

  it("drops a released turn end once the agent has started its next turn", async () => {
    const router = await setUpRouter()
    const watcher = await router.chat()
    const worker = await router.chat()
    await run(
      router.services.db.createSessionSubscription({
        subscriberSessionId: watcher,
        targetSessionId: worker,
        events: ["turn_ended"],
        once: false
      })
    )
    router.routeState.activeTurnSessions.add(watcher)
    await router.emit(worker, { backgroundTasks: [shell] })
    await turn(router, worker, "turn-1", "Started the tests")
    await router.emit(worker, { backgroundTasks: [] })
    await vi.advanceTimersByTimeAsync(HELD_TURN_END_GRACE_MS)

    await router.emit(worker, { initiatedBy: "agent", turnId: "turn-2", turnState: "started" })
    router.routeState.activeTurnSessions.delete(watcher)
    await router.emit(watcher, { turnId: "w-1", turnState: "ended", stopReason: "end_turn" })
    await router.say(worker, "assistant", "Tests passed")
    await router.emit(worker, {
      initiatedBy: "agent",
      stopReason: "end_turn",
      turnId: "turn-2",
      turnState: "ended"
    })
    await waitFor(() => router.eventPrompts().length > 0)

    expect(router.eventPrompts()).toEqual([expect.stringContaining("\nTests passed\n")])
  })
})

describe("released turn ends for a busy subscriber", () => {
  beforeEach(() => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] })
  })
  afterEach(() => vi.useRealTimers())

  it("delivers the turn end once the subscriber's own turn ends", async () => {
    const router = await setUpRouter()
    const watcher = await router.chat()
    const worker = await router.chat()
    await run(
      router.services.db.createSessionSubscription({
        subscriberSessionId: watcher,
        targetSessionId: worker,
        events: ["turn_ended"],
        once: false
      })
    )
    router.routeState.activeTurnSessions.add(watcher)
    await router.emit(worker, { backgroundTasks: [shell] })
    await turn(router, worker, "turn-1", "Tests passed")
    await router.emit(worker, { backgroundTasks: [] })
    await vi.advanceTimersByTimeAsync(HELD_TURN_END_GRACE_MS)

    router.routeState.activeTurnSessions.delete(watcher)
    await router.emit(watcher, { turnId: "w-1", turnState: "ended", stopReason: "end_turn" })
    await waitFor(() => router.eventPrompts().length > 0)

    expect(router.eventPrompts()).toEqual([expect.stringContaining("\nTests passed\n")])
  })
})

describe("final assistant text", () => {
  it.each([
    { name: "a reply older than one transcript page", replied: true, steers: 40, expected: "Done" },
    { name: "a transcript with no reply", replied: false, steers: 2, expected: "" },
    {
      name: "a reply behind more than four pages of steers",
      replied: true,
      steers: 129,
      expected: "Done"
    }
  ])("reads $name", async ({ replied, steers, expected }) => {
    const router = await setUpRouter()
    const session = await router.chat()
    if (replied) await turn(router, session, "turn-1", " Done ")
    for (let index = 0; index < steers; index += 1) {
      await router.say(session, "user", `Steer ${index}`)
    }

    expect(await finalAssistantText(router.services, session)).toBe(expected)
  })
})
