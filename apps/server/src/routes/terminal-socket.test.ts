import { makeTerminalManager } from "@codevisor/terminal"
import { describe, expect, it, onTestFinished } from "vitest"
import { WebSocket, WebSocketServer } from "ws"

import {
  attachTerminalSocket,
  BINARY_OUTPUT,
  BINARY_OUTPUT_RESET,
  coalesceDelayMs,
  encodeBinaryOutput,
  TerminalSocketSender,
  type TerminalSocketLike
} from "./terminal-socket.js"

class FakeSocket implements TerminalSocketLike {
  bufferedAmount = 0
  readonly sent: Array<string | Uint8Array> = []
  readonly callbacks: Array<() => void> = []
  send(data: string | Uint8Array, callback?: () => void): void {
    this.sent.push(data)
    if (callback !== undefined) this.callbacks.push(callback)
  }
}

const manualTimers = () => {
  const immediates: Array<() => void> = []
  const timeouts: Array<{ run: () => void; ms: number }> = []
  return {
    immediates,
    timeouts,
    timers: {
      immediate: (run: () => void) => immediates.push(run),
      timeout: (run: () => void, ms: number) => timeouts.push({ run, ms })
    }
  }
}

const decodeBinary = (frame: Uint8Array) => {
  const view = new DataView(frame.buffer, frame.byteOffset, frame.byteLength)
  return {
    kind: view.getUint8(0),
    seq: Number(view.getBigUint64(1)),
    data: new TextDecoder().decode(frame.subarray(9))
  }
}

describe("terminal socket sender", () => {
  it("batches adjacent output and flushes it ahead of control frames", () => {
    const socket = new FakeSocket()
    const { immediates, timers } = manualTimers()
    const sender = new TerminalSocketSender(socket, {
      binary: false,
      lastOutputSeq: 0,
      resync: () => undefined,
      timers
    })
    sender.sink({ type: "output", seq: 1, data: "a" })
    sender.sink({ type: "output", seq: 2, data: "b" })
    expect(immediates).toHaveLength(1)
    immediates[0]!()
    sender.sink({ type: "output", seq: 3, data: "c" })
    sender.sink({ type: "exit", seq: 4, exitCode: 0 })
    // The scheduled flush for "c" finds nothing left to send.
    immediates[1]!()
    expect(socket.sent.map((data) => JSON.parse(data as string))).toEqual([
      { type: "output", seq: 2, data: "ab" },
      { type: "output", seq: 3, data: "c" },
      { type: "exit", seq: 4, exitCode: 0 }
    ])
    expect(sender.lastSentSeq).toBe(4)
  })

  it("encodes output as binary frames for protocol 2 and sends resets alone", () => {
    const socket = new FakeSocket()
    const sender = new TerminalSocketSender(socket, {
      binary: true,
      lastOutputSeq: 0,
      resync: () => undefined,
      timers: manualTimers().timers
    })
    sender.sink({ type: "output", seq: 9, data: "\u001bcscreen é", reset: true })
    sender.sink({ type: "error", seq: 0, message: "nope" })
    expect(decodeBinary(socket.sent[0] as Uint8Array)).toEqual({
      kind: BINARY_OUTPUT_RESET,
      seq: 9,
      data: "\u001bcscreen é"
    })
    expect(JSON.parse(socket.sent[1] as string)).toEqual({ type: "error", seq: 0, message: "nope" })
    expect(decodeBinary(encodeBinaryOutput(2 ** 40, "x", false))).toEqual({
      kind: BINARY_OUTPUT,
      seq: 2 ** 40,
      data: "x"
    })
  })

  it("drops output for a backed-up socket and resyncs it once drained", () => {
    const socket = new FakeSocket()
    const { immediates, timers } = manualTimers()
    const resyncs: Array<number> = []
    const sender = new TerminalSocketSender(socket, {
      binary: false,
      lastOutputSeq: 5,
      resync: (seq) => resyncs.push(seq),
      highWater: 100,
      lowWater: 10,
      timers
    })
    sender.sink({ type: "output", seq: 6, data: "fits" })
    socket.bufferedAmount = 500
    immediates[0]!()
    // Past the high water mark: later output is dropped, even once batched.
    sender.sink({ type: "output", seq: 7, data: "dropped" })
    sender.sink({ type: "exit", seq: 8 })
    expect(socket.sent).toHaveLength(1)
    // Still draining: no resync yet. Drained: resync from the last sent frame.
    socket.bufferedAmount = 50
    socket.callbacks[0]!()
    expect(resyncs).toEqual([])
    socket.bufferedAmount = 0
    socket.callbacks[0]!()
    expect(resyncs).toEqual([6])
    // A completion on a healthy socket does nothing.
    socket.callbacks[0]!()
    expect(resyncs).toEqual([6])
  })

  it("announces the PTY size only when it changes", () => {
    const socket = new FakeSocket()
    const sender = new TerminalSocketSender(socket, {
      binary: false,
      lastOutputSeq: 0,
      resync: () => undefined,
      timers: manualTimers().timers
    })
    sender.sink({ type: "size", seq: 0, cols: 80, rows: 24 })
    sender.sink({ type: "size", seq: 0, cols: 80, rows: 24 })
    sender.sink({ type: "size", seq: 0, cols: 100, rows: 24 })
    expect(socket.sent.map((data) => JSON.parse(data as string))).toEqual([
      { type: "size", seq: 0, cols: 80, rows: 24 },
      { type: "size", seq: 0, cols: 100, rows: 24 }
    ])
  })

  it("delays output only on slow links", () => {
    expect(coalesceDelayMs(5)).toBe(0)
    expect(coalesceDelayMs(20)).toBe(0)
    expect(coalesceDelayMs(21)).toBe(11)
    expect(coalesceDelayMs(300)).toBe(40)
    const socket = new FakeSocket()
    const { timeouts, timers } = manualTimers()
    const sender = new TerminalSocketSender(socket, {
      binary: false,
      lastOutputSeq: 0,
      resync: () => undefined,
      timers
    })
    sender.setRoundTrip(100)
    sender.sink({ type: "output", seq: 1, data: "slow" })
    expect(timeouts.map((timeout) => timeout.ms)).toEqual([40])
    timeouts[0]!.run()
    expect(socket.sent).toHaveLength(1)
  })

  it("uses real timers by default", async () => {
    const socket = new FakeSocket()
    const sender = new TerminalSocketSender(socket, {
      binary: false,
      lastOutputSeq: 0,
      resync: () => undefined
    })
    sender.sink({ type: "output", seq: 1, data: "now" })
    await new Promise((resolve) => setImmediate(resolve))
    sender.setRoundTrip(30)
    sender.sink({ type: "output", seq: 2, data: "later" })
    await new Promise((resolve) => setTimeout(resolve, 30))
    expect(socket.sent).toHaveLength(2)
  })
})

/// A real WebSocket pair, with the server side attached to `terminalId`.
const connect = async (
  attach: (socket: WebSocket) => Promise<void>
): Promise<{
  client: WebSocket
  messages: Array<unknown>
  sizes: Array<unknown>
  received: (n: number) => Promise<void>
}> => {
  const server = new WebSocketServer({ port: 0 })
  onTestFinished(() => server.close())
  server.on("connection", (socket) => void attach(socket))
  await new Promise<void>((resolve) => server.once("listening", resolve))
  const { port } = server.address() as { port: number }
  const client = new WebSocket(`ws://127.0.0.1:${port}`)
  onTestFinished(() => client.terminate())
  const messages: Array<unknown> = []
  // Size announcements, kept apart from the output the tests follow.
  const sizes: Array<unknown> = []
  const waiters: Array<{ count: number; resolve: () => void }> = []
  client.on("message", (data, isBinary) => {
    const message: unknown = isBinary
      ? decodeBinary(new Uint8Array(data as Buffer))
      : JSON.parse(String(data))
    if ((message as { type?: string }).type === "size") {
      sizes.push(message)
      return
    }
    messages.push(message)
    for (const waiter of waiters.filter((candidate) => messages.length >= candidate.count)) {
      waiter.resolve()
    }
  })
  await new Promise<void>((resolve) => client.once("open", resolve))
  return {
    client,
    messages,
    sizes,
    received: (count) =>
      messages.length >= count
        ? Promise.resolve()
        : new Promise<void>((resolve) => waiters.push({ count, resolve }))
  }
}

const phoneResize = (clientSeq: number) =>
  JSON.stringify({ type: "resize", clientId: "phone", clientSeq, cols: 40, rows: 10 })

describe("terminal socket", () => {
  it("streams binary output, answers pings, and reports bad frames", async () => {
    const manager = makeTerminalManager()
    const handle = manager.registerExternalTerminal(
      { sessionId: "socket-1" },
      {
        write: () => undefined,
        resize: () => undefined,
        kill: () => undefined
      }
    )
    handle.output("history")
    const { client, messages, sizes, received } = await connect((socket) =>
      attachTerminalSocket(manager, handle.terminalId, { lastOutputSeq: 0, protocol: 2 }, socket)
    )
    await received(2)
    client.send(JSON.stringify({ type: "ping", t: 42, srtt: 120 }))
    await received(3)
    handle.output("live")
    await received(4)
    client.send("{")
    client.send(JSON.stringify({ type: "ping" }))
    client.send(JSON.stringify({ type: "input" }))
    client.send(JSON.stringify({ type: "ping", t: 7 }))
    await received(8)
    expect(messages.slice(0, 4)).toEqual([
      { type: "ready", seq: 0, protocol: 2 },
      { kind: BINARY_OUTPUT, seq: 1, data: "history" },
      { type: "pong", seq: 0, t: 42 },
      { kind: BINARY_OUTPUT, seq: 2, data: "live" }
    ])
    expect(messages.slice(4).map((message) => (message as { type: string }).type)).toEqual([
      "error",
      "error",
      "error",
      "pong"
    ])
    // The PTY size is announced once on attach.
    expect(sizes).toEqual([{ type: "size", seq: 0, cols: 80, rows: 24 }])
  })

  it("rejects unknown terminals and resyncs a client that fell behind", async () => {
    const manager = makeTerminalManager()
    const missing = await connect((socket) =>
      attachTerminalSocket(manager, "missing", { lastOutputSeq: 0, protocol: 1 }, socket)
    )
    await missing.received(1)
    expect(missing.messages[0]).toMatchObject({ type: "error" })

    const handle = manager.registerExternalTerminal(
      { sessionId: "socket-2" },
      {
        write: () => undefined,
        resize: () => undefined,
        kill: () => undefined
      }
    )
    // Every send counts as backed up, and every completion as drained: each
    // write is followed by a resubscription from the last delivered frame.
    const { messages, received } = await connect((socket) =>
      attachTerminalSocket(
        manager,
        handle.terminalId,
        { lastOutputSeq: 0, protocol: 1, flowControl: { highWater: -1, lowWater: Infinity } },
        socket
      )
    )
    handle.output("one")
    await received(1)
    await new Promise((resolve) => setTimeout(resolve, 20))
    handle.output("two")
    await received(2)
    expect(messages).toEqual([
      { type: "output", seq: 1, data: "one" },
      { type: "output", seq: 2, data: "two" }
    ])
  })

  it("releases a client's size only once its last socket closes", async () => {
    const manager = makeTerminalManager()
    const released: Array<[string, string]> = []
    const done = Promise.withResolvers<void>()
    const spy = {
      ...manager,
      releaseClient: (terminalId: string, clientId: string) => {
        released.push([terminalId, clientId])
        done.resolve()
      }
    }
    const handle = manager.registerExternalTerminal(
      { sessionId: "socket-3" },
      {
        write: () => undefined,
        resize: () => undefined,
        kill: () => undefined
      }
    )
    const attach = (socket: WebSocket) =>
      attachTerminalSocket(spy, handle.terminalId, { lastOutputSeq: 0, protocol: 2 }, socket)
    // The phone reconnects: its new socket is up before the old one closes.
    const old = await connect(attach)
    old.client.send(phoneResize(1))
    old.client.send(JSON.stringify({ type: "hide", clientId: "phone", clientSeq: 2 }))
    const current = await connect(attach)
    current.client.send(phoneResize(3))
    // Handled frames are acknowledged, so the client can stop keeping them.
    await current.received(2)
    expect(current.messages).toEqual([
      { type: "ready", seq: 0, protocol: 2 },
      { type: "ack", seq: 0, clientSeq: 3 }
    ])
    await new Promise((resolve) => setTimeout(resolve, 20))
    old.client.close()
    await new Promise((resolve) => setTimeout(resolve, 20))
    expect(released).toEqual([])
    current.client.close()
    await done.promise
    expect(released).toEqual([[handle.terminalId, "phone"]])
  })
})
