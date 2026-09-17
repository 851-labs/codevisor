import type { EventEnvelope } from "@codevisor/api"
import { Effect } from "effect"
import { afterEach, describe, expect, it, vi } from "vitest"

import { makeEventFanout, run } from "../server-context.js"
import { attachEventSocket } from "./events.js"

type Frame = Omit<EventEnvelope, "kind"> & { kind: string; previousEventId?: number }

const makeSocket = () => {
  const frames: Frame[] = []
  const closers: Array<() => void> = []
  const listeners = new Set<() => void>()
  const socket = {
    readyState: 1,
    bufferedAmount: 0,
    send: (raw: string) => {
      frames.push(JSON.parse(raw) as Frame)
      for (const listener of listeners) listener()
    },
    on: (_name: string, handler: () => void) => closers.push(handler),
    close: () => {
      socket.readyState = 3
      closers.forEach((handler) => handler())
    }
  }
  const checkpoint = (id: number) =>
    new Promise<void>((resolve) => {
      const check = () => {
        if (frames.some((frame) => frame.id === id)) {
          listeners.delete(check)
          resolve()
        }
      }
      listeners.add(check)
      check()
    })
  return { socket, frames, checkpoint }
}

const attention = (id: number, sidebarState: string): EventEnvelope => ({
  id,
  globalEventId: id,
  subjectRevision: id + 100,
  serverId: "server",
  subjectId: "background-chat",
  kind: "session.attention.updated",
  createdAt: "2026-09-15T00:00:00.000Z",
  payload: { sidebarState }
})

describe("durable shell subscriptions", () => {
  afterEach(() => vi.useRealTimers())

  const fixture = async (since = 1) => {
    vi.useFakeTimers({ toFake: ["setInterval", "clearInterval"] })
    const log: EventEnvelope[] = []
    const fanout = await run(makeEventFanout)
    const listEvents = vi.fn((cursor: number) =>
      Effect.sync(() => log.filter((e) => e.id > cursor))
    )
    const sockets: ReturnType<typeof makeSocket>[] = []
    const connect = async () => {
      const client = makeSocket()
      sockets.push(client)
      await attachEventSocket(
        {
          readSyncBatch: (cursor: number) =>
            Effect.map(listEvents(cursor), (events) => ({
              events,
              cursor: Math.max(cursor, ...events.map((event) => event.id)),
              requiresSnapshot: false
            }))
        } as never,
        fanout,
        since,
        client.socket as never,
        "server",
        undefined,
        25_000,
        true
      )
      return client
    }
    return {
      log,
      fanout,
      listEvents,
      connect,
      close: () => sockets.forEach((c) => c.socket.close())
    }
  }

  it.each(["unread", "idle", "errored", "waitingForUser", "inProgress"])(
    "recovers a missed %s update on every client without navigation or another event",
    async (state) => {
      const f = await fixture()
      try {
        const clients = [await f.connect(), await f.connect()]
        for (const client of clients) {
          expect(client.frames.map((e) => [e.id, e.kind])).toEqual([[1, "keepalive"]])
        }
        f.log.push(attention(2, state))
        await vi.advanceTimersByTimeAsync(25_000)
        await Promise.all(clients.map((client) => client.checkpoint(2)))
        for (const client of clients) {
          expect(client.frames.filter((e) => e.kind !== "keepalive")).toEqual([
            { ...attention(2, state), previousEventId: 1 }
          ])
        }
        // A delayed duplicate broadcast and another heartbeat cannot repeat it.
        await run(f.fanout.publish(attention(2, state)))
        await vi.advanceTimersByTimeAsync(25_000)
        for (const client of clients) {
          expect(client.frames.filter((e) => e.kind !== "keepalive")).toHaveLength(1)
        }
      } finally {
        f.close()
      }
    }
  )

  it("delivers missed and out-of-order broadcasts from the log before advancing the cursor", async () => {
    const f = await fixture()
    try {
      const client = await f.connect()
      f.log.push(attention(2, "unread"), attention(3, "idle"))
      await run(f.fanout.publish(f.log[1]!))
      await client.checkpoint(3)
      await run(f.fanout.publish(f.log[0]!))
      expect(client.frames.filter((e) => e.kind !== "keepalive")).toEqual([
        { ...attention(2, "unread"), previousEventId: 1 },
        { ...attention(3, "idle"), previousEventId: 2 }
      ])
      const reads = f.listEvents.mock.calls.length
      await run(f.fanout.publish({ ...attention(4, "idle"), globalEventId: undefined }))
      expect(f.listEvents).toHaveBeenCalledTimes(reads + 1)
      const project: EventEnvelope = {
        id: 4,
        kind: "project.updated",
        subjectId: "project",
        serverId: "server",
        createdAt: "2026-09-15T00:00:00.000Z",
        payload: {}
      }
      f.log.push(project)
      await run(f.fanout.publish(project))
      await client.checkpoint(4)
      expect(client.frames.at(-1)).toEqual({ ...project, previousEventId: 3 })
    } finally {
      f.close()
    }
  })

  it("drains a change racing a snapshot before checkpointing, without overlapping reads", async () => {
    const f = await fixture()
    const captured = Promise.withResolvers<void>()
    const release = Promise.withResolvers<EventEnvelope[]>()
    f.listEvents.mockImplementationOnce(() =>
      Effect.promise(() => {
        captured.resolve()
        return release.promise
      })
    )
    const connecting = f.connect()
    try {
      await captured.promise
      f.log.push(attention(2, "errored"))
      await run(f.fanout.publish(f.log[0]!))
      await vi.advanceTimersByTimeAsync(25_000)
      expect(f.listEvents).toHaveBeenCalledTimes(1)
      release.resolve([])
      const client = await connecting
      expect(client.frames.map((e) => [e.id, e.kind])).toEqual([
        [2, "session.attention.updated"],
        [2, "keepalive"]
      ])
    } finally {
      release.resolve([])
      await connecting
      f.close()
    }
  })

  it("preserves live-only subscriptions and allows holes in the global log", async () => {
    const f = await fixture(Number.MAX_SAFE_INTEGER)
    try {
      f.log.push(attention(2, "unread"))
      const client = await f.connect()
      await vi.advanceTimersByTimeAsync(25_000)
      expect(f.listEvents).not.toHaveBeenCalled()
      expect(client.frames.map((e) => [e.id, e.kind])).toEqual([
        [0, "keepalive"],
        [0, "keepalive"]
      ])
      f.log.push(attention(8, "unread"))
      await run(f.fanout.publish(f.log[1]!))
      await client.checkpoint(8)
      f.log.push(attention(12, "idle"))
      await vi.advanceTimersByTimeAsync(25_000)
      await client.checkpoint(12)
      expect(
        client.frames.filter((e) => e.kind !== "keepalive").map((e) => [e.previousEventId, e.id])
      ).toEqual([
        [7, 8],
        [8, 12]
      ])
    } finally {
      f.close()
    }
  })

  it("closes on a failed read and removes its timer and subscription", async () => {
    const f = await fixture()
    try {
      const client = await f.connect()
      f.listEvents.mockImplementationOnce(
        () => Effect.fail(new Error("database unavailable")) as never
      )
      await vi.advanceTimersByTimeAsync(25_000)
      expect(client.socket.readyState).toBe(3)
      expect(f.fanout.sinks.size).toBe(0)
      expect(vi.getTimerCount()).toBe(0)
    } finally {
      f.close()
    }
  })

  it.each([false, true])(
    "does not send after closing during a read (has events: %s)",
    async (hasEvents) => {
      const f = await fixture()
      const captured = Promise.withResolvers<void>()
      const release = Promise.withResolvers<EventEnvelope[]>()
      try {
        const client = await f.connect()
        f.listEvents.mockImplementationOnce(() =>
          Effect.promise(() => {
            captured.resolve()
            return release.promise
          })
        )
        const broadcast = run(f.fanout.publish(attention(2, "unread")))
        await captured.promise
        client.socket.close()
        release.resolve(hasEvents ? [attention(2, "unread")] : [])
        await broadcast
        await vi.advanceTimersByTimeAsync(25_000)
        expect(client.frames.map((e) => [e.id, e.kind])).toEqual([[1, "keepalive"]])
        expect(f.listEvents).toHaveBeenCalledTimes(2)
      } finally {
        release.resolve([])
        f.close()
      }
    }
  )
})
