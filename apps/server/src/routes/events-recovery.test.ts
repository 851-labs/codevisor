import { Effect } from "effect"
import { afterEach, describe, expect, it, vi } from "vitest"
import { attachEventSocket } from "./events.js"
import { makeEventFanout } from "../server.js"
import { run } from "../test-support.js"

describe("durable session checkpoints", () => {
  afterEach(() => vi.useRealTimers())

  it("serializes live events with replay, suppresses overlapping replays, and closes on a failed read", async () => {
    const fanout = await run(makeEventFanout)
    const event = (revision: number): import("@codevisor/api").EventEnvelope => ({
      id: revision,
      subjectRevision: revision,
      subjectId: "chat",
      serverId: "server",
      kind: "session.output",
      payload: {},
      createdAt: "2026-09-10T00:00:00.000Z"
    })
    let resolveReplay!: (events: Array<import("@codevisor/api").EventEnvelope>) => void
    let failReplay!: (error: Error) => void
    let reads = 0
    const db = {
      listSubjectEvents: () =>
        Effect.promise(() => {
          reads += 1
          if (reads === 1) return Promise.resolve([])
          return new Promise<Array<import("@codevisor/api").EventEnvelope>>((resolve, reject) => {
            resolveReplay = resolve
            failReplay = reject
          })
        })
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
        "server",
        "chat",
        25_000,
        true
      )
      await vi.advanceTimersByTimeAsync(25_000)
      await run(fanout.publish(event(3)))
      await vi.advanceTimersByTimeAsync(25_000)
      expect(reads).toBe(2)
      expect(sent.map((frame) => frame.id)).toEqual([1])
      resolveReplay([event(2)])
      await vi.advanceTimersByTimeAsync(0)
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

  it("does not replay history for a live-only subscriber before its first event", async () => {
    const fanout = await run(makeEventFanout)
    const listSubjectEvents = vi.fn(() => Effect.succeed([]))
    const sent: Array<{ id: number }> = []
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
        { listSubjectEvents } as never,
        fanout,
        Number.MAX_SAFE_INTEGER,
        socket as never,
        "server",
        "chat",
        25_000,
        true
      )
      await vi.advanceTimersByTimeAsync(25_000)
      expect(listSubjectEvents).not.toHaveBeenCalled()
      expect(sent.map((frame) => frame.id)).toEqual([0, 0])
    } finally {
      socket.close()
    }
  })
})

it("does not checkpoint a socket closed while durable replay was loading", async () => {
  const fanout = await run(makeEventFanout)
  let release!: () => void
  let started!: () => void
  const reading = new Promise<void>((resolve) => {
    started = resolve
  })
  const db = {
    listSubjectEvents: () =>
      Effect.promise(async () => {
        started()
        await new Promise<void>((resolve) => {
          release = resolve
        })
        return []
      })
  }
  const closers: Array<() => void> = []
  const socket = {
    readyState: 1,
    send: vi.fn(),
    on: (_name: string, handler: () => void) => closers.push(handler),
    close: () => {
      socket.readyState = 3
      closers.forEach((handler) => handler())
    }
  }
  const attached = attachEventSocket(
    db as never,
    fanout,
    1,
    socket as never,
    "server",
    "chat",
    25_000,
    true
  )
  await reading
  socket.close()
  release()
  await attached
  expect(socket.send).not.toHaveBeenCalled()
})
