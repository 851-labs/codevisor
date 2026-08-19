import { Effect } from "effect"
import { mkdirSync, mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { describe, expect, it } from "vitest"
import { attachEventSocket } from "./events.js"
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

describe("event routes", () => {
  it("exposes a durable cursor for gapless shell snapshots", async () => {
    const { server, services } = await start()
    expect(await jsonRequest(server, "/v1/events/cursor")).toMatchObject({
      body: { cursor: 0 },
      status: 200
    })

    const project = await run(services.db.createProject({ folderPath: "/tmp/event-cursor" }))
    await run(services.db.appendEvent("project.updated", project.id, { title: "Updated" }))

    expect(await jsonRequest(server, "/v1/events/cursor")).toMatchObject({
      body: { cursor: 1 },
      status: 200
    })
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
      subjectId: "replay"
    }
    const liveEvent = {
      createdAt: "2026-06-30T00:00:01.000Z",
      id: 2,
      kind: "project.updated" as const,
      payload: { id: "live" },
      serverId: "server-a",
      subjectId: "live"
    }
    const server = await startWithApp(
      {
        ...services,
        db: {
          ...services.db,
          listEvents: (since) =>
            since >= Number.MAX_SAFE_INTEGER
              ? Effect.succeed([])
              : Effect.promise(async () => {
                  await run(fanout.publish(liveEvent))
                  return [replayEvent]
                })
        }
      },
      fanout
    )
    runningServers.push(server)

    expect(await readWebSocketEvents(server, 2, 0)).toEqual([replayEvent, liveEvent])
    expect(await readWebSocketEvents(server, 1, 1)).toEqual([liveEvent])
    const liveOnly = readWebSocketEvents(server, 1, Number.MAX_SAFE_INTEGER)
    await new Promise((resolve) => setTimeout(resolve, 20))
    const afterSnapshot = { ...liveEvent, id: 3, payload: { id: "after-snapshot" } }
    await run(fanout.publish(afterSnapshot))
    expect(await liveOnly).toEqual([afterSnapshot])

    const globalFiltered = readWebSocketEvents(server, 1, Number.MAX_SAFE_INTEGER)
    await new Promise((resolve) => setTimeout(resolve, 20))
    await run(
      fanout.publish({
        ...afterSnapshot,
        id: 4,
        subjectId: "session-only",
        subjectRevision: 1
      })
    )
    const globalAfterFilter = { ...afterSnapshot, id: 5, subjectId: "global-after-filter" }
    await run(fanout.publish(globalAfterFilter))
    expect(await globalFiltered).toEqual([globalAfterFilter])

    const scopedFiltered = readWebSocketEvents(
      server,
      1,
      Number.MAX_SAFE_INTEGER,
      "/v1/sessions/target-session/events/socket"
    )
    await new Promise((resolve) => setTimeout(resolve, 20))
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
    await run(fanout.publish(scopedAfterFilter))
    expect(await scopedFiltered).toEqual([{ ...scopedAfterFilter, id: 2 }])

    const sseFiltered = readSseEvents(server, 1, Number.MAX_SAFE_INTEGER)
    await new Promise((resolve) => setTimeout(resolve, 20))
    await run(
      fanout.publish({
        ...afterSnapshot,
        id: 8,
        subjectId: "session-only-sse",
        subjectRevision: 1
      })
    )
    const globalSseEvent = { ...afterSnapshot, id: 9, subjectId: "global-sse" }
    await run(fanout.publish(globalSseEvent))
    expect(await sseFiltered).toEqual([globalSseEvent])
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

    // Session sockets carry keepalives, stamped with the socket's own cursor
    // so no client cursor logic can ever be moved by one.
    const scoped = makeFakeSocket()
    await attachEventSocket(
      services.db,
      fanout,
      Number.MAX_SAFE_INTEGER,
      scoped as never,
      "server-a",
      "session-keepalive",
      5
    )
    await new Promise((resolve) => setTimeout(resolve, 40))
    const keepalives = scoped.sent.map(parse).filter((event) => event.kind === "keepalive")
    expect(keepalives.length).toBeGreaterThan(0)
    expect(keepalives[0]).toMatchObject({ id: 0, kind: "keepalive" })
    expect(JSON.parse(scoped.sent[0]!)).toMatchObject({
      serverId: "server-a",
      subjectId: "session-keepalive",
      payload: {}
    })

    // After real traffic, keepalives carry the advanced cursor.
    await run(
      fanout.publish({
        createdAt: "2026-06-30T00:00:00.000Z",
        id: 41,
        kind: "session.output",
        payload: {},
        serverId: "server-a",
        subjectId: "session-keepalive",
        subjectRevision: 7
      })
    )
    await new Promise((resolve) => setTimeout(resolve, 40))
    expect(
      scoped.sent
        .map(parse)
        .filter((event) => event.kind === "keepalive")
        .at(-1)?.id
    ).toBe(7)

    // Close stops the timer.
    scoped.close()
    const sentAtClose = scoped.sent.length
    await new Promise((resolve) => setTimeout(resolve, 40))
    expect(scoped.sent.length).toBe(sentAtClose)

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
      undefined,
      5
    )
    await new Promise((resolve) => setTimeout(resolve, 40))
    expect(global.sent).toEqual([])
    global.close()
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
