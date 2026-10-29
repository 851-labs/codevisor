import type { Notification } from "@modelcontextprotocol/sdk/types.js"
import { describe, expect, it, vi } from "vitest"

import { createEventStreams, type StreamExtra } from "./event-streams.js"
import { manualClock } from "./plugin-server-test-support.js"

const opening = {
  name: "test.ping",
  accountId: undefined,
  position: { cursor: null, truncated: false },
  backlog: []
}

const extraFor = (
  signal: AbortSignal,
  sendNotification: (notification: Notification) => Promise<void>
): StreamExtra => ({
  requestId: 7,
  signal,
  sendNotification,
  sendRequest: () => Promise.reject(new Error("unused"))
})

const closedResult = {
  resultType: "complete",
  _meta: { "io.modelcontextprotocol/subscriptionId": 7 }
}

describe("createEventStreams", () => {
  it("closes a stream whose notification cannot be delivered", async () => {
    const clock = manualClock()
    const streams = createEventStreams({ clock, heartbeatCursor: () => null })
    const send = vi.fn(() => Promise.reject(new Error("transport closed")))

    const closed = await streams.open(opening, extraFor(new AbortController().signal, send))

    expect(closed).toEqual(closedResult)
    expect(streams.count()).toBe(0)
    expect(clock.timers()).toBe(0)
  })

  it("never opens a stream that was cancelled before its handler ran", async () => {
    const clock = manualClock()
    const streams = createEventStreams({ clock, heartbeatCursor: () => null })
    const cancelled = new AbortController()
    cancelled.abort()
    const send = vi.fn(() => Promise.resolve())

    await expect(streams.open(opening, extraFor(cancelled.signal, send))).resolves.toEqual(
      closedResult
    )
    expect(send).not.toHaveBeenCalled()
    expect(clock.timers()).toBe(0)
  })

  it("ends a stream when its lifetime passes and stops its timers", async () => {
    const clock = manualClock()
    const streams = createEventStreams({ clock, heartbeatCursor: () => null })
    const send = vi.fn(() => Promise.resolve())
    const ended = vi.fn()

    const closing = streams
      .open({ ...opening, lifetimeMs: 60_000 }, extraFor(new AbortController().signal, send))
      .then(ended)
    clock.advance(59_999)
    await Promise.resolve()
    const openBeforeLifetime = streams.count()
    clock.advance(1)
    await closing

    expect(openBeforeLifetime).toBe(1)
    expect(ended).toHaveBeenCalledWith(closedResult)
    expect(streams.count()).toBe(0)
    expect(clock.timers()).toBe(0)
  })

  it("asks for each stream's own heartbeat cursor", async () => {
    const clock = manualClock()
    const streams = createEventStreams({
      clock,
      heartbeatCursor: (stream) => `cursor-${stream.accountId}`
    })
    const sent: Array<Notification> = []
    const cancel = new AbortController()

    const closing = streams.open(
      { ...opening, accountId: "work" },
      extraFor(cancel.signal, async (notification) => {
        sent.push(notification)
      })
    )
    clock.advance(15_000)
    cancel.abort()
    await closing

    expect(sent.at(-1)).toMatchObject({
      method: "notifications/events/heartbeat",
      params: { cursor: "cursor-work" }
    })
    expect(clock.timers()).toBe(0)
  })
})
