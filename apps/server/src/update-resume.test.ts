import { mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

import { makeFilePausedTurnStore, type PausedTurn } from "./paused-turns.js"
import { makeEventFanout } from "./server-context.js"
import {
  archiveSessionViaWorkspace,
  idleRouteState,
  makeServices,
  run,
  tempDirs
} from "./test-support.js"
import { markTurnInterrupted, withInterruptedStop } from "./turn-interruptions.js"
import {
  continueAfterUpdate,
  makeUpdateResumer,
  UPDATE_RESUME_STAGGER_MS
} from "./update-resume.js"

const pausedAt = "2026-10-20T00:00:00.000Z"

const paused = (...sessionIds: ReadonlyArray<string>): ReadonlyArray<PausedTurn> =>
  sessionIds.map((sessionId) => ({ sessionId, turnId: `turn-${sessionId}`, pausedAt }))

const makeStorePath = (): string => {
  const root = mkdtempSync(join(tmpdir(), "codevisor-paused-"))
  tempDirs.push(root)
  return join(root, "paused-for-update.json")
}

const makeHarness = (path = makeStorePath()) => {
  const pausedTurns = makeFilePausedTurnStore(path)
  const continued: Array<string> = []
  const logs: Array<string> = []
  const resumer = makeUpdateResumer({
    pausedTurns,
    continueSession: async (sessionId) => {
      if (sessionId === "broken") throw new Error("session is gone")
      continued.push(sessionId)
    },
    log: (line) => logs.push(line)
  })
  return { path, pausedTurns, continued, logs, resumer }
}

const pendingIds = (harness: ReturnType<typeof makeHarness>): ReadonlyArray<string> =>
  harness.pausedTurns.read().map((turn) => turn.sessionId)

describe("update resumer", () => {
  beforeEach(() => vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] }))
  afterEach(() => vi.useRealTimers())

  it("staggers the continues so paused chats do not all start at once", async () => {
    const harness = makeHarness()
    harness.pausedTurns.add(paused("a", "b", "c"))

    harness.resumer.resume(harness.pausedTurns.read())
    await vi.advanceTimersByTimeAsync(0)
    expect(harness.continued).toEqual(["a"])

    await vi.advanceTimersByTimeAsync(UPDATE_RESUME_STAGGER_MS - 1)
    expect(harness.continued).toEqual(["a"])
    await vi.advanceTimersByTimeAsync(1)
    expect(harness.continued).toEqual(["a", "b"])

    await vi.advanceTimersByTimeAsync(UPDATE_RESUME_STAGGER_MS)
    expect(harness.continued).toEqual(["a", "b", "c"])
    expect(pendingIds(harness)).toEqual([])
    expect(harness.logs).toEqual(["Continuing 3 chat(s) paused for the update"])
  })

  it("drops a chat's continue when the user sends it something first", async () => {
    const harness = makeHarness()
    harness.pausedTurns.add(paused("a", "b"))
    harness.resumer.resume(harness.pausedTurns.read())
    await vi.advanceTimersByTimeAsync(0)
    expect(harness.resumer.isPending("b")).toBe(true)

    harness.resumer.cancel("b")
    harness.resumer.cancel("never-paused")

    expect(harness.resumer.isPending("b")).toBe(false)
    expect(pendingIds(harness)).toEqual([])
    await vi.advanceTimersByTimeAsync(UPDATE_RESUME_STAGGER_MS * 2)
    expect(harness.continued).toEqual(["a"])
  })

  it("keeps waiting continues on disk when the server stops before they fire", async () => {
    const first = makeHarness()
    first.pausedTurns.add(paused("a", "b"))
    first.resumer.resume(first.pausedTurns.read())
    await vi.advanceTimersByTimeAsync(0)

    first.resumer.close()
    await vi.advanceTimersByTimeAsync(UPDATE_RESUME_STAGGER_MS)
    expect(first.continued).toEqual(["a"])

    const second = makeHarness(first.path)
    second.resumer.resume(second.pausedTurns.read())
    second.resumer.resume(second.pausedTurns.read())
    await vi.advanceTimersByTimeAsync(0)
    expect(second.continued).toEqual(["b"])
    expect(pendingIds(second)).toEqual([])
  })

  it("forgets a continue that fails instead of retrying it on every boot", async () => {
    const harness = makeHarness()
    harness.pausedTurns.add(paused("broken"))

    harness.resumer.resume(harness.pausedTurns.read())
    await vi.advanceTimersByTimeAsync(0)

    expect(pendingIds(harness)).toEqual([])
    expect(harness.logs).toContain("Could not continue broken after the update: session is gone")
  })

  it("treats an unreadable paused-turn file as nothing to resume", () => {
    const harness = makeHarness()
    writeFileSync(harness.path, "{not json")
    expect(harness.pausedTurns.read()).toEqual([])
    writeFileSync(harness.path, JSON.stringify({ turns: [{ sessionId: 7 }] }))
    expect(harness.pausedTurns.read()).toEqual([])
  })
})

const makeChat = async () => {
  const { services } = await makeServices("server-a")
  const fanout = await run(makeEventFanout)
  const idle = idleRouteState()
  const routeState = { ...idle, restart: { ...idle.restart, isGated: () => true } }
  const project = await run(
    services.db.createProject({ folderPath: "/tmp/codevisor-continue", name: "Repo" })
  )
  const session = await run(
    services.db.createSession({
      agentSessionId: "agent-paused",
      harnessId: "codex",
      projectId: project.id,
      title: "Paused"
    })
  )
  await run(services.db.createPromptQueueItem(session.id, "queued earlier"))
  const queuedTexts = async () =>
    (await run(services.db.listPromptQueue(session.id))).map((item) => item.text)
  const continueChat = () =>
    continueAfterUpdate(services, fanout, routeState, "server-a", session.id)
  return { services, routeState, project, session, queuedTexts, continueChat }
}

describe("continuing a paused chat", () => {
  it("puts a hidden continue ahead of prompts queued before the update", async () => {
    const chat = await makeChat()

    await chat.continueChat()

    const queue = await run(chat.services.db.listPromptQueue(chat.session.id))
    expect(queue.map((item) => [item.text, item.origin])).toEqual([
      ["continue", "system"],
      ["queued earlier", undefined]
    ])
  })

  it("leaves a chat alone once it is running again or archived", async () => {
    const chat = await makeChat()
    chat.routeState.activeTurnSessions.add(chat.session.id)
    await chat.continueChat()
    expect(await chat.queuedTexts()).toEqual(["queued earlier"])

    chat.routeState.activeTurnSessions.clear()
    await archiveSessionViaWorkspace(chat.services, chat.project.id, chat.session.id)
    await chat.continueChat()
    expect(await chat.queuedTexts()).toEqual(["queued earlier"])
  })

  it("marks an interrupted turn's end without overriding a harness stop kind", async () => {
    const { services } = await makeServices("server-a")
    const ended = { initiatedBy: "user", turnId: "turn-1", turnState: "ended" }
    const event = { kind: "session.updated" as const, subjectId: "agent", payload: ended }
    expect(withInterruptedStop(services, "session", event, ended)).toBe(event)

    markTurnInterrupted(services, "session")
    expect(withInterruptedStop(services, "session", event, ended).payload).toEqual({
      ...ended,
      stopKind: "interrupted"
    })
    const signedOut = { ...ended, stopKind: "authRequired" }
    const signedOutEvent = { ...event, payload: signedOut }
    expect(withInterruptedStop(services, "session", signedOutEvent, signedOut)).toBe(signedOutEvent)
  })
})
