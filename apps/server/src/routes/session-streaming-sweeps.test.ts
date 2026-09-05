import { mkdirSync, mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { describe, expect, it, vi } from "vitest"
import {
  appendAndPublish,
  defaultServerConfig,
  makeEventFanout,
  reconcileStaleStreamingTurns,
  startCodevisorServer
} from "../server.js"
import type { RouteState } from "../server.js"
import { drainPromptQueue, makeTurnDispatchListener } from "./prompt-queue.js"
import {
  jsonRequest,
  makeServices,
  run,
  runningServers,
  tempDirs,
  idleRestartCoordinator,
  waitFor
} from "../test-support.js"

describe("streaming turn sweeps and prompt gating", () => {
  it("sweeps quiet orphaned streaming turns while the server keeps running", async () => {
    const { services } = await makeServices("server-a")
    const folder = mkdtempSync(join(tmpdir(), "codevisor-stale-sweep-"))
    tempDirs.push(folder)
    const emptyRouteState = (): RouteState => ({
      activePromptSessions: new Set(),
      activeTurnSessions: new Set(),
      gatedSessions: new Map(),
      pendingPromptActions: new Set(),
      pendingSessionCreates: new Map(),
      turnHeldSessions: new Set(),
      updateSignature: {},
      restartHeldSessions: new Set(),
      restart: idleRestartCoordinator()
    })

    // Strand a turn "in the past": its harness died (or its terminal event
    // was lost) six minutes ago and nothing has been appended since.
    const strandedSession = async () => {
      const project = await run(services.db.createProject({ folderPath: folder }))
      const created = await run(
        services.db.createSession({
          projectId: project.id,
          harnessId: "codex",
          agentSessionId: "stale-sweep-agent"
        })
      )
      await run(
        services.db.appendEvent("session.updated", created.id, {
          initiatedBy: "user",
          turnId: "stale-sweep-turn",
          turnState: "started"
        })
      )
      await run(
        services.db.appendEvent("session.output", created.id, {
          role: "assistant",
          text: "half-finished answer"
        })
      )
      // The turn died while a question was pending; the sweep must pair it
      // before ending the turn.
      await run(
        services.db.appendEvent("session.output", created.id, {
          sessionUpdate: "question",
          questionId: "stale-sweep-question",
          questions: [
            {
              id: "choice",
              question: "Continue?",
              options: [{ label: "Yes" }],
              allowsOther: false
            }
          ]
        })
      )
      // A second stranded row that never had turn accounting: the terminal
      // event must close it without turn fields.
      const turnless = await run(
        services.db.createSession({
          projectId: project.id,
          harnessId: "codex",
          agentSessionId: "stale-sweep-turnless"
        })
      )
      await run(
        services.db.appendEvent("session.output", turnless.id, {
          role: "assistant",
          text: "no turn id"
        })
      )
      // A streaming row stranded mid-transcript (the conversation moved past
      // it): repaired without a terminal event, since the newest item is not
      // an in-progress turn.
      const midTranscript = await run(
        services.db.createSession({
          projectId: project.id,
          harnessId: "codex",
          agentSessionId: "stale-sweep-mid-transcript"
        })
      )
      await run(
        services.db.appendConversationItem(
          midTranscript.id,
          "assistant",
          "stale-mid-message",
          "half-finished answer",
          true
        )
      )
      await run(
        services.db.appendConversationItem(midTranscript.id, "user", "follow-up", "hello?", false)
      )
      return { session: created, turnless, midTranscript }
    }
    vi.useFakeTimers({ toFake: ["Date"] })
    let session!: Awaited<ReturnType<typeof strandedSession>>["session"]
    let turnless!: Awaited<ReturnType<typeof strandedSession>>["turnless"]
    let midTranscript!: Awaited<ReturnType<typeof strandedSession>>["midTranscript"]
    try {
      vi.setSystemTime(Date.now() - 6 * 60 * 1000)
      ;({ session, turnless, midTranscript } = await strandedSession())
    } finally {
      vi.useRealTimers()
    }

    const fanout = await run(makeEventFanout)

    // A drain that still owns the session's turn keeps the sweep away: long
    // silent tool runs are quiet on the event log but perfectly alive.
    const owned = emptyRouteState()
    owned.activePromptSessions.add(session.id)
    owned.activePromptSessions.add(turnless.id)
    owned.activePromptSessions.add(midTranscript.id)
    expect(await reconcileStaleStreamingTurns(services, fanout, owned, "server-a")).toBe(0)
    expect(await run(services.db.getTranscriptPage(session.id, undefined, 8))).toMatchObject({
      items: [{ role: "assistant", isGenerating: true }]
    })

    // Unowned and quiet: the sweep closes every stranded row.
    expect(
      await reconcileStaleStreamingTurns(services, fanout, emptyRouteState(), "server-a")
    ).toBe(3)
    const repairedPage = await run(services.db.getTranscriptPage(session.id, undefined, 8))
    expect(repairedPage).toMatchObject({
      items: [
        {
          role: "assistant",
          isGenerating: false,
          stopReason: "interrupted",
          stopDetail: expect.stringContaining("stopped streaming")
        }
      ]
    })
    // The orphaned question was paired before the turn ended.
    expect(repairedPage.pendingQuestion).toBeUndefined()
    // The turnless row is closed by a terminal event without turn fields.
    expect(await run(services.db.getTranscriptPage(turnless.id, undefined, 8))).toMatchObject({
      items: [{ role: "assistant", isGenerating: false, stopReason: "interrupted" }]
    })
    // The mid-transcript row is repaired quietly — the conversation had
    // already moved on, so no terminal turn event is published.
    expect(await run(services.db.getTranscriptPage(midTranscript.id, undefined, 8))).toMatchObject({
      items: [
        { role: "assistant", isGenerating: false, stopReason: "interrupted" },
        { role: "user", text: "hello?" }
      ]
    })
    // The repair flows through the event pipeline: connected clients receive
    // a live terminal event instead of discovering the row on a full reload.
    const events = await run(services.db.listSubjectEvents(session.id))
    expect(events.map((event) => event.kind)).toContain("session.updated")
    expect(
      events.some(
        (event) =>
          event.kind === "session.updated" &&
          typeof event.payload === "object" &&
          event.payload !== null &&
          (event.payload as { stopReason?: string }).stopReason === "interrupted"
      )
    ).toBe(true)

    // Idempotent: nothing left to repair.
    expect(
      await reconcileStaleStreamingTurns(services, fanout, emptyRouteState(), "server-a")
    ).toBe(0)
  })

  it("spares streaming turns with recent event activity", async () => {
    const { services } = await makeServices("server-a")
    const folder = mkdtempSync(join(tmpdir(), "codevisor-live-sweep-"))
    tempDirs.push(folder)
    const project = await run(services.db.createProject({ folderPath: folder }))
    const session = await run(
      services.db.createSession({
        projectId: project.id,
        harnessId: "codex",
        agentSessionId: "live-sweep-agent"
      })
    )
    await run(
      services.db.appendEvent("session.output", session.id, {
        role: "assistant",
        text: "still streaming right now"
      })
    )

    const fanout = await run(makeEventFanout)
    const routeState: RouteState = {
      activePromptSessions: new Set(),
      activeTurnSessions: new Set(),
      gatedSessions: new Map(),
      pendingPromptActions: new Set(),
      pendingSessionCreates: new Map(),
      turnHeldSessions: new Set(),
      updateSignature: {},
      restartHeldSessions: new Set(),
      restart: idleRestartCoordinator()
    }
    expect(await reconcileStaleStreamingTurns(services, fanout, routeState, "server-a")).toBe(0)
    expect(await run(services.db.getTranscriptPage(session.id, undefined, 8))).toMatchObject({
      items: [{ role: "assistant", isGenerating: true }]
    })
  })

  it("holds prompt dispatch while a harness-initiated turn is active and re-drains when it ends", async () => {
    const { agents, services } = await makeServices("server-a")
    const folder = mkdtempSync(join(tmpdir(), "codevisor-turn-hold-project-"))
    tempDirs.push(folder)
    const project = await run(services.db.createProject({ folderPath: folder }))
    const session = await run(
      services.db.createSession({
        projectId: project.id,
        harnessId: "codex",
        agentSessionId: "agent-turn-hold"
      })
    )
    const fanout = await run(makeEventFanout)
    const routeState: RouteState = {
      activePromptSessions: new Set(),
      activeTurnSessions: new Set(),
      gatedSessions: new Map(),
      pendingPromptActions: new Set(),
      pendingSessionCreates: new Map(),
      turnHeldSessions: new Set(),
      updateSignature: {},
      restartHeldSessions: new Set(),
      restart: idleRestartCoordinator()
    }
    const unsubscribe = fanout.subscribe(
      makeTurnDispatchListener(services, fanout, routeState, "server-a")
    )

    // The harness started a turn on its own (a task-notification follow-up
    // after a background task finished) — no prompt drain owns it.
    await appendAndPublish(services.db, fanout, "session.updated", session.id, {
      initiatedBy: "agent",
      turnId: "agent-turn-1",
      turnState: "started"
    })
    expect(routeState.activeTurnSessions.has(session.id)).toBe(true)

    // A prompt sent mid-turn stays queued instead of being injected into the
    // live turn (where the turn's result would resolve it prematurely).
    await run(services.db.createPromptQueueItem(session.id, "queued behind agent turn"))
    await drainPromptQueue(services, fanout, routeState, "server-a", session.id)
    expect(agents.prompts).toEqual([])
    expect(routeState.turnHeldSessions.has(session.id)).toBe(true)
    expect(await run(services.db.listPromptQueue(session.id))).toMatchObject([
      { text: "queued behind agent turn" }
    ])

    const userTurnEnded = Promise.withResolvers<void>()
    const stopWatching = fanout.subscribe((event) => {
      const payload = event.payload as { turnState?: string; turnId?: string }
      if (
        event.subjectId === session.id &&
        payload?.turnState === "ended" &&
        payload.turnId !== "agent-turn-1"
      )
        userTurnEnded.resolve()
    })
    // The turn's terminal event releases the hold and dispatches the prompt.
    await appendAndPublish(services.db, fanout, "session.updated", session.id, {
      initiatedBy: "agent",
      stopReason: "end_turn",
      turnId: "agent-turn-1",
      turnState: "ended"
    })
    await waitFor(
      () => agents.prompts.length === 1,
      () => `prompts: ${JSON.stringify(agents.prompts)}`
    )
    expect(agents.prompts[0]).toEqual(["agent-turn-hold", "queued behind agent turn"])
    await waitFor(async () => (await run(services.db.listPromptQueue(session.id))).length === 0)
    await userTurnEnded.promise
    stopWatching()
    expect(routeState.activeTurnSessions.has(session.id)).toBe(false)
    expect(routeState.turnHeldSessions.has(session.id)).toBe(false)

    // Malformed payloads are tolerated: a terminal event whose payload is not
    // an object still clears the turn instead of throwing.
    const listener = makeTurnDispatchListener(services, fanout, routeState, "server-a")
    for (const malformed of ["boom", null, ["boom"]]) {
      routeState.activeTurnSessions.add(session.id)
      listener({
        id: 999,
        serverId: "server-a",
        kind: "session.error",
        subjectId: session.id,
        createdAt: "2026-08-23T00:00:00.000Z",
        payload: malformed
      } as never)
      expect(routeState.activeTurnSessions.has(session.id)).toBe(false)
    }
    unsubscribe()
  })

  it("holds the next queued prompt when a turn begins mid-drain", async () => {
    const { agents, services } = await makeServices("server-a")
    const folder = mkdtempSync(join(tmpdir(), "codevisor-middrain-hold-project-"))
    tempDirs.push(folder)
    const project = await run(services.db.createProject({ folderPath: folder }))
    const session = await run(
      services.db.createSession({
        projectId: project.id,
        harnessId: "codex",
        agentSessionId: "agent-middrain-hold"
      })
    )
    const fanout = await run(makeEventFanout)
    const routeState: RouteState = {
      activePromptSessions: new Set(),
      activeTurnSessions: new Set(),
      gatedSessions: new Map(),
      pendingPromptActions: new Set(),
      pendingSessionCreates: new Map(),
      turnHeldSessions: new Set(),
      updateSignature: {},
      restartHeldSessions: new Set(),
      restart: idleRestartCoordinator()
    }
    // Simulate a task-notification turn starting the instant the first
    // dispatched turn ends — before the drain loop claims the next item.
    const unsubscribe = fanout.subscribe((event) => {
      const payload = event.payload as Record<string, unknown>
      if (event.kind === "session.updated" && payload.turnState === "ended") {
        routeState.activeTurnSessions.add(session.id)
      }
    })

    await run(services.db.createPromptQueueItem(session.id, "first"))
    await run(services.db.createPromptQueueItem(session.id, "second"))
    await drainPromptQueue(services, fanout, routeState, "server-a", session.id)

    expect(agents.prompts).toEqual([["agent-middrain-hold", "first"]])
    expect(routeState.turnHeldSessions.has(session.id)).toBe(true)
    expect(await run(services.db.listPromptQueue(session.id))).toMatchObject([{ text: "second" }])
    unsubscribe()
  })

  it("adopts a client-supplied messageId as the queue item and echo id", async () => {
    const { services } = await makeServices("server-prompt-message-id")
    const server = await run(
      startCodevisorServer(
        services,
        defaultServerConfig({ id: "server-prompt-message-id", port: 0 })
      )
    )
    runningServers.push(server)
    const folder = join(mkdtempSync(join(tmpdir(), "codevisor-prompt-id-")), "repo")
    mkdirSync(folder, { recursive: true })
    const project = (
      await jsonRequest(server, "/v1/projects", {
        body: JSON.stringify({ folderPath: folder }),
        method: "POST"
      })
    ).body as { readonly id: string }
    const session = (
      await jsonRequest(server, "/v1/sessions", {
        body: JSON.stringify({ projectId: project.id, harnessId: "codex", title: "Identity" }),
        method: "POST"
      })
    ).body as { readonly id: string }

    const messageId = "0f6b2c8e-8a34-4b9d-9f2e-1a7c5d3e9b01"
    const accepted = await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
      body: JSON.stringify({ text: "run pwd", messageId }),
      method: "POST"
    })
    expect(accepted.status).toBe(202)
    expect((accepted.body as { queueItemId?: string }).queueItemId).toBe(messageId)

    // The user echo event carries the client's id back, so clients can
    // reconcile their optimistic message by identity.
    await waitFor(async () =>
      (await run(services.db.listSubjectEvents(session.id))).some(
        (event) =>
          event.kind === "session.output" &&
          (event.payload as { messageId?: string }).messageId === messageId &&
          (event.payload as { role?: string }).role === "user"
      )
    )
  })
})
