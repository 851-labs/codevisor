import { EventEmitter } from "node:events"

import type { EventEnvelope } from "@codevisor/api"
import { Effect } from "effect"
import { expect, it, onTestFinished, vi } from "vitest"

import { makeEventFanout } from "../server.js"
import { run } from "../test-support.js"
import { handleEvents } from "./events.js"
import { attachSyncEventSocket } from "./sync-event-socket.js"

const event = (revision: number): EventEnvelope => ({
  id: revision,
  subjectRevision: revision,
  subjectId: "chat",
  serverId: "local",
  kind: "session.output",
  payload: {},
  createdAt: "2026-09-16"
})
const sink = () => {
  const socket = Object.assign(new EventEmitter(), {
    bufferedAmount: 0,
    send: vi.fn(),
    close: vi.fn((_code?: number, _reason?: string) => {
      socket.emit("close")
    })
  })
  onTestFinished(() => {
    socket.emit("close")
  })
  return socket
}

it("resnapshots expired cursors and slow consumers before buffering more journal data", async () => {
  const fanout = await run(makeEventFanout)
  for (const condition of ["expired", "already full", "became full"]) {
    const socket = sink()
    const readSyncBatch = vi.fn(() =>
      Effect.succeed({
        events: [event(2), event(3)],
        cursor: 3,
        requiresSnapshot: condition === "expired"
      })
    )
    if (condition === "already full") socket.bufferedAmount = 1024 * 1024 + 1
    if (condition === "became full")
      socket.send.mockImplementation(() => {
        socket.bufferedAmount = 1024 * 1024 + 1
      })
    await attachSyncEventSocket({ readSyncBatch } as never, fanout, 1, socket, "local", "chat")
    const frames = socket.send.mock.calls.map(([raw]) => JSON.parse(raw))
    expect(frames.at(-1)).toMatchObject({
      kind: "snapshot_required",
      id: condition === "already full" ? 1 : 3
    })
    expect(socket.close).toHaveBeenCalledWith(1000, "snapshot required")
    expect(frames.filter((f) => f.kind === "session.output")).toHaveLength(
      condition === "became full" ? 1 : 0
    )
  }
})

it("ignores unrelated or duplicate notifications and does not send after closing during a read", async () => {
  const fanout = await run(makeEventFanout)
  const socket = sink()
  const started = Promise.withResolvers<void>()
  const released = Promise.withResolvers<{
    events: EventEnvelope[]
    cursor: number
    requiresSnapshot: boolean
  }>()
  const readSyncBatch = vi.fn(() =>
    Effect.promise(() => {
      started.resolve()
      return released.promise
    })
  )
  const attached = attachSyncEventSocket(
    { readSyncBatch } as never,
    fanout,
    1,
    socket,
    "local",
    "chat"
  )
  await started.promise
  await run(fanout.publish({ ...event(2), subjectRevision: undefined }))
  await run(fanout.publish(event(1)))
  await run(fanout.publish({ ...event(2), subjectId: "other" }))
  socket.close()
  released.resolve({ events: [event(2)], cursor: 2, requiresSnapshot: false })
  await attached
  expect(socket.send).not.toHaveBeenCalled()
  expect(readSyncBatch).toHaveBeenCalledTimes(1)
})

it("closes an SSE consumer whose outbound buffer is full", async () => {
  const fanout = await run(makeEventFanout)
  const response = Object.assign(new EventEmitter(), {
    writableLength: 2 * 1024 * 1024,
    writeHead: vi.fn(),
    write: vi.fn(),
    end: vi.fn(() => {
      response.emit("close")
    })
  })
  await handleEvents({} as never, fanout, new URL("http://localhost/v1/events"), response as never)
  expect(response.end).toHaveBeenCalledOnce()
  expect(response.write).toHaveBeenCalledWith("event: snapshot_required\n")
})
