import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { EventEnvelope, ExecutionJob } from "@codevisor/api"
import { describe, expect, it, onTestFinished, vi } from "vitest"

import { appendAndPublish, makeEventFanout } from "../server-context.js"
import { idleRouteState, makeServices, run, tempDirs, waitFor } from "../test-support.js"
import { makeTurnDispatchListener } from "./prompt-queue.js"
import { makeSessionEventOutbox } from "./session-event-outbox.js"
import { finalAssistantText, makeSessionEventRouter } from "./session-event-router.js"

const setUpRouter = async () => {
  const { agents, services } = await makeServices("server-a")
  const fanout = await run(makeEventFanout)
  const routeState = idleRouteState()
  const outbox = makeSessionEventOutbox(services, fanout, routeState, "server-a")
  const router = makeSessionEventRouter(services, outbox, async () => {})
  onTestFinished(fanout.subscribe(router.listener))
  onTestFinished(
    fanout.subscribe(makeTurnDispatchListener(services, fanout, routeState, "server-a"))
  )
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
  const watch = (subscriberSessionId: string, targetSessionId: string) =>
    run(
      services.db.createSessionSubscription({
        subscriberSessionId,
        targetSessionId,
        events: ["turn_ended"],
        once: false
      })
    )
  const queuedFor = async (sessionId: string) =>
    (await run(services.db.listPromptQueue(sessionId))).map((item) => item.text)
  return { services, routeState, router, chat, emit, say, eventPrompts, watch, queuedFor }
}

type Router = Awaited<ReturnType<typeof setUpRouter>>

const ATTENTION_SETTLE_GRACE_MS = 12_000

const shell = { id: "task-1", description: "bun run dev", status: "running", taskType: "shell" }
const subagent = { id: "task-2", description: "Review", status: "running", taskType: "subagent" }

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

describe("turn ends", () => {
  it("reports a turn that leaves a dev server running as soon as it ends", async () => {
    const router = await setUpRouter()
    const watcher = await router.chat()
    const worker = await router.chat()
    await router.watch(watcher, worker)

    await router.emit(worker, { backgroundTasks: [shell] })
    await turn(router, worker, "turn-1", "Dev server is up")
    await waitFor(() => router.eventPrompts().length > 0)

    const [delivered, ...rest] = router.eventPrompts()
    expect(rest).toEqual([])
    expect(delivered).toContain(
      `<codevisor-event type="session.turn_ended" agentId="${worker}" title="New Session" stopReason="end_turn"`
    )
    expect(delivered).toContain(">\nDev server is up\n</codevisor-event>")
  })

  it("reports a turn held by a running subagent once it settles", async () => {
    vi.useFakeTimers({ toFake: ["Date"] })
    onTestFinished(() => {
      vi.useRealTimers()
    })
    const router = await setUpRouter()
    const watcher = await router.chat()
    const worker = await router.chat()
    await router.watch(watcher, worker)

    await router.emit(worker, { backgroundTasks: [subagent] })
    await turn(router, worker, "turn-1", "Waiting on the review")
    await router.emit(worker, { backgroundTasks: [] })
    const beforeSettle = await router.queuedFor(watcher)
    vi.setSystemTime(new Date(Date.now() + ATTENTION_SETTLE_GRACE_MS))
    await run(router.services.db.settleSessionAttention(worker))
    await router.emit(worker, {}, "session.attention.updated")
    await waitFor(() => router.eventPrompts().length > 0)

    expect(beforeSettle).toEqual([])
    expect(router.eventPrompts()).toEqual([expect.stringContaining("\nWaiting on the review\n")])
  })

  it("sends a finished turn it never got to announce when it recovers", async () => {
    const router = await setUpRouter()
    const watcher = await router.chat()
    const worker = await router.chat()
    await router.watch(watcher, worker)
    const append = (payload: object, kind: EventEnvelope["kind"] = "session.updated") =>
      run(router.services.db.appendEvent(kind, worker, payload))

    await append({ initiatedBy: "user", turnId: "turn-1", turnState: "started" })
    await append({ role: "assistant", text: "Finished before the restart" }, "session.output")
    await append({ stopReason: "end_turn", turnId: "turn-1", turnState: "ended" })
    await router.router.recover()
    await waitFor(() => router.eventPrompts().length > 0)
    await router.router.recover()

    expect(router.eventPrompts()).toEqual([
      expect.stringContaining("\nFinished before the restart\n")
    ])
    expect(await run(router.services.db.listFinishedTurns)).toEqual([])
  })
})

describe("busy subscribers", () => {
  it("get a turn end after their own turn, even once the agent has moved on", async () => {
    const router = await setUpRouter()
    const watcher = await router.chat()
    const worker = await router.chat()
    await router.watch(watcher, worker)
    router.routeState.activeTurnSessions.add(watcher)

    await turn(router, worker, "turn-1", "First pass done")
    await waitFor(async () => (await router.queuedFor(watcher)).length === 1)
    await router.emit(worker, { initiatedBy: "agent", turnId: "turn-2", turnState: "started" })
    const whileBusy = router.eventPrompts()
    await router.emit(watcher, { turnId: "w-1", turnState: "ended", stopReason: "end_turn" })
    await waitFor(() => router.eventPrompts().length > 0)

    expect(whileBusy).toEqual([])
    expect(router.eventPrompts()).toEqual([expect.stringContaining("\nFirst pass done\n")])
  })

  it("get every event that queued up while they were busy, in order, in one prompt", async () => {
    const router = await setUpRouter()
    const watcher = await router.chat()
    const first = await router.chat()
    const second = await router.chat()
    await router.watch(watcher, first)
    await router.watch(watcher, second)
    router.routeState.activeTurnSessions.add(watcher)

    await turn(router, first, "a-1", "one")
    await waitFor(async () => (await router.queuedFor(watcher)).length === 1)
    await turn(router, second, "b-1", "two")
    await waitFor(async () => (await router.queuedFor(watcher)).length === 2)
    await turn(router, first, "a-2", "three")
    await waitFor(async () => (await router.queuedFor(watcher)).length === 3)
    await router.emit(watcher, { turnId: "w-1", turnState: "ended", stopReason: "end_turn" })
    await waitFor(() => router.eventPrompts().length > 0)

    const [delivered, ...rest] = router.eventPrompts()
    expect(rest).toEqual([])
    const positions = ["\none\n", "\ntwo\n", "\nthree\n"].map((reply) => delivered!.indexOf(reply))
    expect(positions.every((position) => position >= 0)).toBe(true)
    expect(positions.toSorted((left, right) => left - right)).toEqual(positions)
  })
})

describe("finished jobs", () => {
  it("skip a caller that already collected the result but still reach subscribers", async () => {
    const router = await setUpRouter()
    const caller = await router.chat()
    const watcher = await router.chat()
    await run(
      router.services.db.createSessionSubscription({
        subscriberSessionId: watcher,
        targetSessionId: caller,
        events: ["job_finished"],
        once: false
      })
    )
    const job: ExecutionJob = {
      jobId: "j-1",
      sessionId: caller,
      description: "Build",
      state: "completed",
      startedAt: "2026-10-27T00:00:00.000Z",
      elapsedMs: 1,
      running: [],
      logs: [],
      outputPath: "/tmp/j-1.log"
    }

    router.router.onJobFinished({ job, collected: () => true })
    await waitFor(() => router.eventPrompts().length > 0)

    expect(await router.queuedFor(caller)).toEqual([])
    expect(router.eventPrompts()).toEqual([expect.stringContaining('jobId="j-1"')])
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

describe("usage-limit turn ends", () => {
  it("tells subscribers the agent paused at its usage limit instead of sending no final message", async () => {
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
    const stopDetail = "You've hit your session limit · resets 4:30pm."

    await router.emit(worker, { initiatedBy: "user", turnId: "turn-1", turnState: "started" })
    await router.emit(worker, {
      initiatedBy: "user",
      stopReason: "end_turn",
      stopKind: "usageLimit",
      stopDetail,
      turnId: "turn-1",
      turnState: "ended"
    })
    await waitFor(() => router.eventPrompts().length > 0)

    const [delivered] = router.eventPrompts()
    expect(delivered).toContain('stopReason="end_turn" stopKind="usageLimit"')
    expect(delivered).toContain(`Paused at its usage limit: ${stopDetail}`)
    expect(delivered).not.toContain("(no final message)")
  })
})
