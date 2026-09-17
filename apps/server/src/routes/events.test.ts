import { mkdirSync, mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { Effect } from "effect"
import { afterEach, describe, expect, it, vi } from "vitest"

import { CodevisorServer, makeEventFanout } from "../server.js"
import {
  jsonRequest,
  makeServices,
  readSseEvents,
  readWebSocketEvents,
  run,
  runningServers,
  start,
  startWithApp,
  tempDirs
} from "../test-support.js"
import { attachEventSocket } from "./events.js"

describe("event routes", () => {
  afterEach(() => {
    vi.useRealTimers()
    vi.restoreAllMocks()
  })
  it("exposes a durable cursor for gapless shell snapshots", async () => {
    const { server, services } = await start()
    expect(await jsonRequest(server, "/v1/events/cursor")).toMatchObject({
      body: { cursor: 0 },
      status: 200
    })

    const project = await run(services.db.createProject({ folderPath: "/tmp/event-cursor" }))
    const appended = await run(
      services.db.appendEvent("project.updated", project.id, { title: "Updated" })
    )

    expect(await jsonRequest(server, "/v1/events/cursor")).toMatchObject({
      body: { cursor: appended.globalEventId },
      status: 200
    })
  })

  it("negotiates durable shell replay and an immediate checkpoint", async () => {
    const { server, services } = await start()
    const event = await run(
      services.db.appendEvent("project.updated", "project", { title: "Updated" })
    )
    const frames = await readWebSocketEvents(server, 2, "0&sync=1", "/v1/events/socket", true)
    expect(frames).toEqual([
      { ...event, previousEventId: 0 },
      expect.objectContaining({ id: event.id, kind: "keepalive", subjectId: "" })
    ])
  })

  it("persists and fans out agent-initiated events with no prompt in flight", async () => {
    const { agents, server, services } = await start()
    const workspaceRoot = mkdtempSync(join(tmpdir(), "codevisor-server-background-"))
    tempDirs.push(workspaceRoot)
    const workspaceFolder = join(workspaceRoot, "codevisor")
    mkdirSync(workspaceFolder)
    const workspace = (
      await jsonRequest(server, "/v1/projects", {
        body: JSON.stringify({ folderPath: workspaceFolder }),
        method: "POST"
      })
    ).body as { readonly id: string }
    const session = (
      await jsonRequest(server, "/v1/sessions", {
        body: JSON.stringify({ projectId: workspace.id, harnessId: "codex", title: "Background" }),
        method: "POST"
      })
    ).body as { readonly id: string; readonly agentSessionId: string }

    // The standing sink was registered at session create; the agent now pushes
    // a whole background turn without any client prompt in flight.
    // Scalar payloads are wrapped rather than crashing materialization.
    await agents.emit(session.agentSessionId, {
      kind: "session.output",
      subjectId: session.agentSessionId,
      payload: "scalar-status-line"
    })
    await agents.emit(session.agentSessionId, {
      kind: "session.updated",
      subjectId: session.agentSessionId,
      payload: { initiatedBy: "agent", turnId: "turn-bg", turnState: "started" }
    })
    await agents.emit(session.agentSessionId, {
      kind: "session.output",
      subjectId: session.agentSessionId,
      payload: {
        content: { text: "Background task finished.", type: "text" },
        messageId: "assistant-bg",
        sessionUpdate: "agent_message_chunk"
      }
    })
    await agents.emit(session.agentSessionId, {
      kind: "session.updated",
      subjectId: session.agentSessionId,
      payload: {
        initiatedBy: "agent",
        stopReason: "end_turn",
        turnId: "turn-bg",
        turnState: "ended"
      }
    })

    const sessionEvents = await run(services.db.listSubjectEvents(session.id))
    const assistantItemId = (
      await run(services.db.getTranscriptPage(session.id, undefined, 8))
    ).items.find((item) => item.role === "assistant")?.id
    expect(assistantItemId).toBeDefined()
    expect(sessionEvents).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          kind: "session.updated",
          payload: expect.objectContaining({
            chatItemId: assistantItemId,
            initiatedBy: "agent",
            turnState: "started"
          })
        }),
        expect.objectContaining({
          kind: "session.output",
          payload: expect.objectContaining({
            chatItemId: assistantItemId,
            messageId: "assistant-bg"
          })
        }),
        expect.objectContaining({
          kind: "session.updated",
          payload: expect.objectContaining({
            chatItemId: assistantItemId,
            stopReason: "end_turn",
            turnState: "ended"
          })
        })
      ])
    )
    const detail = await run(services.db.getSessionDetail(session.id))
    expect(detail.conversation.map((item) => item.text)).toContain("Background task finished.")
  })

  it("buffers event websocket fanout that arrives during replay", async () => {
    const { services } = await makeServices("server-a")
    const fanout = await run(makeEventFanout)
    const replayEvent = {
      createdAt: "2026-06-30T00:00:00.000Z",
      id: 1,
      kind: "project.created" as const,
      payload: { id: "replay" },
      serverId: "server-a",
      subjectId: "replay",
      globalEventId: 1
    }
    const liveEvent = {
      createdAt: "2026-06-30T00:00:01.000Z",
      id: 2,
      kind: "project.updated" as const,
      payload: { id: "live" },
      serverId: "server-a",
      subjectId: "live",
      globalEventId: 2
    }
    const durable: Array<import("@codevisor/api").EventEnvelope> = [replayEvent]
    let firstRead = true
    const server = await startWithApp(
      {
        ...services,
        db: {
          ...services.db,
          readSyncBatch: (since, subject) =>
            Effect.promise(async () => {
              const events = durable.filter((event) =>
                subject === undefined
                  ? event.globalEventId !== undefined && event.globalEventId > since
                  : event.subjectId === subject && (event.subjectRevision ?? 0) > since
              )
              if (firstRead) {
                firstRead = false
                durable.push(liveEvent)
                await run(fanout.publish(liveEvent))
              }
              return { events, cursor: events.at(-1)?.id ?? since, requiresSnapshot: false }
            })
        }
      },
      fanout
    )
    const publish = async (event: import("@codevisor/api").EventEnvelope) => {
      durable.push(event as typeof replayEvent)
      await run(fanout.publish(event))
    }
    runningServers.push(server)

    expect(await readWebSocketEvents(server, 2, 0)).toEqual([
      { ...replayEvent, previousEventId: 0 },
      { ...liveEvent, previousEventId: 1 }
    ])
    expect(await readWebSocketEvents(server, 1, 1)).toEqual([{ ...liveEvent, previousEventId: 1 }])
    const subscribe = fanout.subscribe.bind(fanout)
    const subscription = vi.spyOn(fanout, "subscribe")
    const nextSubscription = () => {
      const ready = Promise.withResolvers<void>()
      subscription.mockImplementationOnce((listener) => {
        const unsubscribe = subscribe(listener)
        ready.resolve()
        return unsubscribe
      })
      return ready.promise
    }
    let subscribed = nextSubscription()
    const liveOnly = readWebSocketEvents(server, 1, Number.MAX_SAFE_INTEGER)
    await subscribed
    const afterSnapshot = {
      ...liveEvent,
      id: 3,
      globalEventId: 3,
      payload: { id: "after-snapshot" }
    }
    await publish(afterSnapshot)
    expect(await liveOnly).toEqual([{ ...afterSnapshot, previousEventId: 2 }])

    subscribed = nextSubscription()
    const globalFiltered = readWebSocketEvents(server, 1, Number.MAX_SAFE_INTEGER)
    await subscribed
    await run(
      fanout.publish({
        ...afterSnapshot,
        id: 4,
        globalEventId: undefined,
        subjectId: "session-only",
        subjectRevision: 1
      })
    )
    const globalAfterFilter = {
      ...afterSnapshot,
      id: 5,
      globalEventId: 5,
      subjectId: "global-after-filter"
    }
    await publish(globalAfterFilter)
    expect(await globalFiltered).toEqual([{ ...globalAfterFilter, previousEventId: 4 }])

    subscribed = nextSubscription()
    const scopedFiltered = readWebSocketEvents(
      server,
      1,
      Number.MAX_SAFE_INTEGER,
      "/v1/sessions/target-session/events/socket"
    )
    await subscribed
    await run(
      fanout.publish({
        ...afterSnapshot,
        id: 6,
        subjectId: "other-session",
        subjectRevision: 1
      })
    )
    const scopedAfterFilter = {
      ...afterSnapshot,
      id: 7,
      subjectId: "target-session",
      subjectRevision: 2
    }
    await publish(scopedAfterFilter)
    expect(await scopedFiltered).toEqual([{ ...scopedAfterFilter, id: 2, previousEventId: 1 }])

    subscribed = nextSubscription()
    const sseFiltered = readSseEvents(server, 1, Number.MAX_SAFE_INTEGER)
    await subscribed
    await run(
      fanout.publish({
        ...afterSnapshot,
        id: 8,
        globalEventId: undefined,
        subjectId: "session-only-sse",
        subjectRevision: 1
      })
    )
    const globalSseEvent = { ...afterSnapshot, id: 9, globalEventId: 9, subjectId: "global-sse" }
    await publish(globalSseEvent)
    expect(await sseFiltered).toEqual([{ ...globalSseEvent, previousEventId: 8 }])
  })

  it("interleaves keepalives on session sockets so silence is measurable", async () => {
    const { services } = await makeServices("server-a")
    const fanout = await run(makeEventFanout)
    const makeFakeSocket = () => {
      const sent: string[] = []
      const closers: Array<() => void> = []
      return {
        sent,
        readyState: 1, // WebSocket.OPEN
        send: (raw: string) => sent.push(raw),
        on: (event: string, handler: () => void) => {
          if (event === "close") closers.push(handler)
        },
        close: () => closers.forEach((handler) => handler())
      }
    }
    const parse = (raw: string): { kind: string; id: number } =>
      JSON.parse(raw) as { kind: string; id: number }

    vi.useFakeTimers({ toFake: ["Date", "setInterval", "clearInterval"] })
    // Session sockets carry keepalives, stamped with the socket's own cursor
    // so no client cursor logic can ever be moved by one.
    const scoped = makeFakeSocket()
    await attachEventSocket(
      services.db,
      fanout,
      Number.MAX_SAFE_INTEGER,
      scoped as never,
      "server-a",
      "session-keepalive"
    )
    await vi.advanceTimersByTimeAsync(25_000)
    const keepalives = scoped.sent.map(parse).filter((event) => event.kind === "keepalive")
    expect(keepalives.length).toBeGreaterThan(0)
    expect(keepalives[0]).toMatchObject({ id: 0, kind: "keepalive" })
    expect(JSON.parse(scoped.sent[0]!)).toMatchObject({
      serverId: "server-a",
      subjectId: "session-keepalive",
      payload: {}
    })

    // Fanout wakes a durable read; only committed records advance the cursor.
    const project = await run(services.db.createProject({ folderPath: "/tmp/keepalive" }))
    const session = await run(
      services.db.createSession({ projectId: project.id, harnessId: "codex", title: "Keepalive" })
    )
    scoped.close()
    const connected = makeFakeSocket()
    await attachEventSocket(services.db, fanout, 0, connected as never, "server-a", session.id)
    const committed = await run(services.db.appendEvent("session.output", session.id, {}))
    await run(fanout.publish(committed))
    await vi.advanceTimersByTimeAsync(25_000)
    expect(
      connected.sent
        .map(parse)
        .filter((event) => event.kind === "keepalive")
        .at(-1)?.id
    ).toBe(committed.subjectRevision)

    // Close stops the timer.
    connected.close()
    const sentAtClose = connected.sent.length
    await vi.advanceTimersByTimeAsync(25_000)
    expect(connected.sent.length).toBe(sentAtClose)

    // The global socket stays keepalive-free: old live-only subscribers adopt
    // the first received id as their cursor, which a keepalive must never
    // influence.
    const global = makeFakeSocket()
    await attachEventSocket(
      services.db,
      fanout,
      Number.MAX_SAFE_INTEGER,
      global as never,
      "server-a",
      undefined
    )
    await vi.advanceTimersByTimeAsync(25_000)
    expect(global.sent.map(parse)).toEqual([
      expect.objectContaining({ id: 0, kind: "keepalive" }),
      expect.objectContaining({ id: 0, kind: "keepalive" })
    ])
    global.close()
  })

  it("repairs a lost completion from durable events and checkpoints replay before reporting caught up", async () => {
    const fanout = await run(makeEventFanout)
    const durable: Array<import("@codevisor/api").EventEnvelope> = [1, 2].map((revision) => ({
      id: revision,
      subjectRevision: revision,
      subjectId: "chat",
      serverId: "server-a",
      kind: "session.output" as const,
      createdAt: "2026-09-10T00:00:00.000Z",
      payload: {}
    }))
    const db = {
      readSyncBatch: (since: number) =>
        Effect.sync(() => ({
          events: durable.filter((event) => event.id > since),
          cursor: durable.at(-1)?.id ?? since,
          requiresSnapshot: false
        }))
    }
    const sent: Array<{ id: number; kind: string }> = []
    const closers: Array<() => void> = []
    const socket = {
      readyState: 1,
      send: (raw: string) => sent.push(JSON.parse(raw)),
      on: (_name: string, handler: () => void) => closers.push(handler),
      close: () => {
        socket.readyState = 3
        closers.forEach((handler) => handler())
      }
    }
    vi.useFakeTimers({ toFake: ["setInterval", "clearInterval"] })
    try {
      await attachEventSocket(
        db as never,
        fanout,
        1,
        socket as never,
        "server-a",
        "chat",
        25_000,
        true
      )
      expect(sent.map(({ id, kind }) => [id, kind])).toEqual([
        [2, "session.output"],
        [2, "keepalive"]
      ])
      // Persisted but deliberately never published to the live fanout.
      durable.push({
        ...durable[1]!,
        id: 3,
        subjectRevision: 3,
        kind: "session.updated",
        payload: { status: "idle" }
      })
      await vi.advanceTimersByTimeAsync(25_000)
      expect(sent.slice(-2).map(({ id, kind }) => [id, kind])).toEqual([
        [3, "session.updated"],
        [3, "keepalive"]
      ])
      await vi.advanceTimersByTimeAsync(25_000)
      expect(sent.filter((event) => event.kind !== "keepalive").map((event) => event.id)).toEqual([
        2, 3
      ])
    } finally {
      socket.close()
    }
  })

  it("exposes an Effect service layer and EventFanout subscription", async () => {
    const { services } = await makeServices("layered")
    const layered = await run(
      Effect.gen(function* () {
        const server = yield* CodevisorServer
        return yield* server.db.getUpdateInfo
      }).pipe(Effect.provide(CodevisorServer.layer(services)))
    )
    expect(layered.currentVersion).toBe("0.1.0")

    const fanout = await run(makeEventFanout)
    const events: Array<unknown> = []
    const unsubscribe = fanout.subscribe((event) => events.push(event))
    await run(
      fanout.publish({
        createdAt: "2026-06-30T00:00:00.000Z",
        id: 1,
        kind: "update.changed",
        payload: {},
        serverId: "server-a",
        subjectId: "update"
      })
    )
    unsubscribe()
    expect(events).toHaveLength(1)
  })
})
