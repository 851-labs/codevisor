import { once } from "node:events"
import { mkdirSync, mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { decode } from "@codevisor/api"
import { Effect } from "effect"
import { afterEach, describe, expect, it, onTestFinished, vi } from "vitest"
import { WebSocket } from "ws"

import { makeEventFanout } from "../server.js"
import {
  jsonRequest,
  makeServices,
  readSseEvents,
  readWebSocketEvents,
  run,
  start,
  startWithApp,
  tempDirs,
  listSubjectEvents
} from "../test-support.js"
import { idOf } from "./response-test-support.js"
import {
  CreatedSession,
  memoryDatabase,
  parseFrame,
  type EventSink
} from "./session-test-support.js"
import { attachSyncEventSocket } from "./sync-event-socket.js"

const makeFakeSocket = () => {
  const sent: string[] = []
  const closers: Array<() => void> = []
  const socket = {
    sent,
    readyState: 1,
    bufferedAmount: 0,
    send: (raw: string) => sent.push(raw),
    on: (event: string, handler: () => void) => {
      if (event === "close") closers.push(handler)
    },
    close: () => closers.forEach((handler) => handler())
  }
  const sink: EventSink = socket
  return Object.assign(socket, { sink })
}

const parseSentEvent = parseFrame

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
    const workspace = {
      id: idOf(
        (
          await jsonRequest(server, "/v1/projects", {
            body: JSON.stringify({ folderPath: workspaceFolder }),
            method: "POST"
          })
        ).body
      )
    }
    const session = decode(CreatedSession)(
      (
        await jsonRequest(server, "/v1/sessions", {
          body: JSON.stringify({
            projectId: workspace.id,
            harnessId: "codex",
            title: "Background"
          }),
          method: "POST"
        })
      ).body
    )

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

    const sessionEvents = listSubjectEvents(services, session.id)
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
      durable.push(event)
      await run(fanout.publish(event))
    }

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

    vi.useFakeTimers({ toFake: ["Date", "setInterval", "clearInterval"] })
    const scoped = makeFakeSocket()
    await attachSyncEventSocket(
      services.db,
      fanout,
      Number.MAX_SAFE_INTEGER,
      scoped.sink,
      "server-a",
      "session-keepalive"
    )
    await vi.advanceTimersByTimeAsync(25_000)
    const keepalives = scoped.sent.map(parseSentEvent).filter((event) => event.kind === "keepalive")
    expect(keepalives.length).toBeGreaterThan(0)
    expect(keepalives[0]).toMatchObject({ id: 0, kind: "keepalive" })
    expect(JSON.parse(scoped.sent[0]!)).toMatchObject({
      serverId: "server-a",
      subjectId: "session-keepalive",
      payload: {}
    })

    const project = await run(services.db.createProject({ folderPath: "/tmp/keepalive" }))
    const session = await run(
      services.db.createSession({ projectId: project.id, harnessId: "codex", title: "Keepalive" })
    )
    scoped.close()
    const connected = makeFakeSocket()
    await attachSyncEventSocket(services.db, fanout, 0, connected.sink, "server-a", session.id)
    const committed = await run(services.db.appendEvent("session.output", session.id, {}))
    await run(fanout.publish(committed))
    await vi.advanceTimersByTimeAsync(25_000)
    expect(
      connected.sent.map(parseSentEvent).findLast((event) => event.kind === "keepalive")?.id
    ).toBe(committed.subjectRevision)

    connected.close()
    const sentAtClose = connected.sent.length
    await vi.advanceTimersByTimeAsync(25_000)
    expect(connected.sent.length).toBe(sentAtClose)

    const global = makeFakeSocket()
    await attachSyncEventSocket(
      services.db,
      fanout,
      Number.MAX_SAFE_INTEGER,
      global.sink,
      "server-a",
      undefined
    )
    await vi.advanceTimersByTimeAsync(25_000)
    expect(global.sent.map(parseSentEvent)).toEqual([
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
    const db = await memoryDatabase({
      readSyncBatch: (since) =>
        Effect.sync(() => ({
          events: durable.filter((event) => event.id > since),
          cursor: durable.at(-1)?.id ?? since,
          requiresSnapshot: false
        }))
    })
    const sent: Array<{ id: number; kind: string }> = []
    const closers: Array<() => void> = []
    const socket = {
      readyState: 1,
      bufferedAmount: 0,
      send: (raw: string) => sent.push(parseFrame(raw)),
      on: (_name: string, handler: () => void) => closers.push(handler),
      close: () => {
        socket.readyState = 3
        closers.forEach((handler) => handler())
      }
    }
    const sink: EventSink = socket
    vi.useFakeTimers({ toFake: ["setInterval", "clearInterval"] })
    try {
      await attachSyncEventSocket(db, fanout, 1, sink, "server-a", "chat", 25_000)
      expect(sent.map(({ id, kind }) => [id, kind])).toEqual([
        [2, "session.output"],
        [2, "keepalive"]
      ])
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
})

describe("websocket upgrades", () => {
  it("closes a socket that sends a malformed frame and keeps serving", async () => {
    const { server } = await start()
    const socket = new WebSocket(`${server.url.replace("http:", "ws:")}/v1/events/socket?since=0`)
    onTestFinished(() => socket.terminate())
    await once(socket, "open")
    const closed = once(socket, "close")
    socket.send(Buffer.from([0xff, 0xfe]), { binary: false })
    const [code] = await closed
    expect(code).toBe(1007)
    expect((await jsonRequest(server, "/v1/health")).status).toBe(200)
  })
})
