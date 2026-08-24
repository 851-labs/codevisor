import { decodeRelayEnvelopes } from "@codevisor/api"
import { describe, expect, it } from "vitest"
import { RelayOutbox } from "./machine-socket.js"

const makeOutbox = (coalesceMs: number, maxBufferedBytes?: number) => {
  const messages: { header: unknown; payload: Uint8Array }[][] = []
  const timers: { callback: () => void; delayMs: number; cancelled: boolean }[] = []
  const outbox = new RelayOutbox({
    send: (message) =>
      messages.push(
        decodeRelayEnvelopes(message).map((envelope) => ({
          header: envelope.header,
          payload: new Uint8Array(envelope.payload)
        }))
      ),
    scheduleTimeout: (callback, delayMs) => {
      const timer = { callback, delayMs, cancelled: false }
      timers.push(timer)
      return () => {
        timer.cancelled = true
      }
    },
    coalesceMs,
    ...(maxBufferedBytes === undefined ? {} : { maxBufferedBytes })
  })
  return { outbox, messages, timers }
}

const header = (seq: number): unknown => ({
  peerId: "p",
  frame: { t: "data", channelId: "c", seq }
})

describe("RelayOutbox", () => {
  it("sends immediately with coalescing disabled", () => {
    const { outbox, messages, timers } = makeOutbox(0)
    outbox.push(header(0), new Uint8Array([1]))
    outbox.push(header(1), new Uint8Array([2]))
    expect(messages).toHaveLength(2)
    expect(timers).toHaveLength(0)
  })

  it("coalesces pushes within the window into one ordered message", () => {
    const { outbox, messages, timers } = makeOutbox(5)
    outbox.push(header(0), new Uint8Array([1]))
    outbox.push(header(1), new Uint8Array([2, 2]))
    expect(messages).toHaveLength(0)
    expect(timers).toHaveLength(1)
    expect(timers[0]!.delayMs).toBe(5)

    timers[0]!.callback()
    expect(messages).toHaveLength(1)
    expect(messages[0]!.map((envelope) => [...envelope.payload])).toEqual([[1], [2, 2]])
    expect(messages[0]!.map((envelope) => envelope.header)).toEqual([header(0), header(1)])

    // The next push after a flush arms a fresh timer.
    outbox.push(header(2), new Uint8Array([3]))
    expect(timers).toHaveLength(2)
  })

  it("flushes early when the buffered bytes cross the threshold", () => {
    const { outbox, messages, timers } = makeOutbox(5, 1024)
    outbox.push(header(0), new Uint8Array(512))
    expect(messages).toHaveLength(0)
    outbox.push(header(1), new Uint8Array(512))
    expect(messages).toHaveLength(1)
    expect(messages[0]).toHaveLength(2)
    expect(timers[0]!.cancelled).toBe(true)
  })

  it("flush is a no-op with nothing buffered, and clear drops silently", () => {
    const { outbox, messages, timers } = makeOutbox(5)
    outbox.flush()
    expect(messages).toHaveLength(0)

    outbox.push(header(0), new Uint8Array([1]))
    outbox.clear()
    timers[0]!.callback()
    expect(messages).toHaveLength(0)
    expect(timers[0]!.cancelled).toBe(true)
  })
})
