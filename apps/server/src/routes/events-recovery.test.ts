import { Effect } from "effect"
import { afterEach, describe, expect, it, vi } from "vitest"

import { makeEventFanout } from "../server.js"
import { run } from "../test-support.js"
import { attachEventSocket } from "./events.js"

const outputEvent = (revision: number): import("@codevisor/api").EventEnvelope => ({
  id: revision,
  subjectRevision: revision,
  subjectId: "chat",
  serverId: "server",
  kind: "session.output",
  payload: {},
  createdAt: "2026-09-10T00:00:00.000Z"
})

describe("durable session checkpoints", () => {
  afterEach(() => vi.useRealTimers())

  it("serializes live events with replay, suppresses overlapping replays, and closes on a failed read", async () => {
    const fanout = await run(makeEventFanout)
    let resolveReplay!: (events: Array<import("@codevisor/api").EventEnvelope>) => void
    let failReplay!: (error: Error) => void
    let reads = 0
    const db = {
      readSyncBatch: (since: number) =>
        Effect.promise(() => {
          reads += 1
          if (reads === 1)
            return Promise.resolve({ events: [], cursor: since, requiresSnapshot: false })
          if (reads === 3)
            return Promise.resolve({ events: [outputEvent(3)], cursor: 3, requiresSnapshot: false })
          return new Promise<Array<import("@codevisor/api").EventEnvelope>>((resolve, reject) => {
            resolveReplay = resolve
            failReplay = reject
          }).then((events) => ({
            events,
            cursor: events.at(-1)?.id ?? since,
            requiresSnapshot: false
          }))
        })
    }
    const delivered = Promise.withResolvers<void>()
    const sent: Array<{ id: number; kind: string }> = []
    const closers: Array<() => void> = []
    const socket = {
      readyState: 1,
      send: (raw: string) => {
        const event = JSON.parse(raw)
        sent.push(event)
        if (event.id === 3 && event.kind === "keepalive") delivered.resolve()
      },
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
        "server",
        "chat",
        25_000,
        true
      )
      await vi.advanceTimersByTimeAsync(25_000)
      await run(fanout.publish(outputEvent(3)))
      await vi.advanceTimersByTimeAsync(25_000)
      expect(reads).toBe(2)
      expect(sent.map((frame) => frame.id)).toEqual([1])
      resolveReplay([outputEvent(2)])
      await delivered.promise
      expect(sent.map(({ id, kind }) => [id, kind])).toEqual([
        [1, "keepalive"],
        [2, "session.output"],
        [3, "session.output"],
        [3, "keepalive"]
      ])
      await vi.advanceTimersByTimeAsync(25_000)
      failReplay(new Error("database unavailable"))
      await vi.advanceTimersByTimeAsync(0)
      expect(socket.readyState).toBe(3)
    } finally {
      socket.close()
    }
  })
})
