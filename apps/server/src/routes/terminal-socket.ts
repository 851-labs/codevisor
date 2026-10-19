import {
  decode,
  TerminalClientFrame,
  TerminalPingFrame,
  type TerminalServerFrame
} from "@codevisor/api"
import type { TerminalManagerService } from "@codevisor/terminal"
import { WebSocket } from "ws"

import { failureMessage, run } from "../server-context.js"

export const TERMINAL_SOCKET_HIGH_WATER = 1024 * 1024
export const TERMINAL_SOCKET_LOW_WATER = 256 * 1024

export const BINARY_OUTPUT = 1
export const BINARY_OUTPUT_RESET = 2
const HEADER_BYTES = 9

const encoder = new TextEncoder()

export const encodeBinaryOutput = (seq: number, data: string, reset: boolean): Uint8Array => {
  const body = encoder.encode(data)
  const frame = new Uint8Array(HEADER_BYTES + body.length)
  const view = new DataView(frame.buffer)
  view.setUint8(0, reset ? BINARY_OUTPUT_RESET : BINARY_OUTPUT)
  view.setBigUint64(1, BigInt(seq))
  frame.set(body, HEADER_BYTES)
  return frame
}

export const coalesceDelayMs = (roundTripMs: number): number =>
  roundTripMs <= 20 ? 0 : Math.min(40, Math.max(2, Math.round(roundTripMs / 2)))

export interface TerminalSocketLike {
  readonly bufferedAmount: number
  send(data: string | Uint8Array, callback?: (error?: Error) => void): void
}

export interface TerminalSocketTimers {
  readonly immediate: (task: () => void) => void
  readonly timeout: (task: () => void, ms: number) => void
}

const realTimers: TerminalSocketTimers = {
  immediate: (task) => setImmediate(task),
  timeout: (task, ms) => {
    setTimeout(task, ms)
  }
}

export class TerminalSocketSender {
  private batch: Array<string> = []
  private batchSeq = 0
  private flushScheduled = false
  private stale = false
  private lastSize: string | undefined
  private delayMs = 0
  lastSentSeq: number
  private readonly highWater: number
  private readonly lowWater: number

  constructor(
    private readonly socket: TerminalSocketLike,
    private readonly options: {
      readonly binary: boolean
      readonly lastOutputSeq: number
      readonly resync: (lastSentSeq: number) => void
      readonly highWater?: number
      readonly lowWater?: number
      readonly timers?: TerminalSocketTimers
    }
  ) {
    this.lastSentSeq = options.lastOutputSeq
    this.highWater = options.highWater ?? TERMINAL_SOCKET_HIGH_WATER
    this.lowWater = options.lowWater ?? TERMINAL_SOCKET_LOW_WATER
  }

  setRoundTrip(roundTripMs: number): void {
    this.delayMs = coalesceDelayMs(roundTripMs)
  }

  readonly sink = (frame: TerminalServerFrame): void => {
    if (this.stale) return
    if (frame.type === "size") {
      const key = `${frame.cols}x${frame.rows}`
      if (key === this.lastSize) return
      this.lastSize = key
    }
    if (frame.type === "output" && frame.reset !== true) {
      this.batch.push(frame.data)
      this.batchSeq = frame.seq
      this.scheduleFlush()
      return
    }
    this.flush()
    this.write(frame)
  }

  private scheduleFlush(): void {
    if (this.flushScheduled) return
    this.flushScheduled = true
    const timers = this.options.timers ?? realTimers
    const flushBatch = (): void => {
      this.flushScheduled = false
      this.flush()
    }
    if (this.delayMs === 0) timers.immediate(flushBatch)
    else timers.timeout(flushBatch, this.delayMs)
  }

  private flush(): void {
    if (this.batch.length === 0) return
    const data = this.batch.join("")
    this.batch = []
    this.write({ type: "output", seq: this.batchSeq, data })
  }

  private write(frame: TerminalServerFrame): void {
    const encoded =
      this.options.binary && frame.type === "output"
        ? encodeBinaryOutput(frame.seq, frame.data, frame.reset === true)
        : JSON.stringify(frame)
    this.lastSentSeq = Math.max(this.lastSentSeq, frame.seq)
    this.socket.send(encoded, () => this.sent())
    if (this.socket.bufferedAmount > this.highWater) {
      this.stale = true
      this.batch = []
    }
  }

  private sent(): void {
    if (!this.stale) return
    if (this.socket.bufferedAmount > this.lowWater) return
    this.stale = false
    this.options.resync(this.lastSentSeq)
  }
}

const openSockets = new Map<string, number>()

const sendError = (webSocket: WebSocket, cause: unknown): void => {
  webSocket.send(JSON.stringify({ type: "error", seq: 0, message: failureMessage(cause) }))
}

export const attachTerminalSocket = async (
  terminal: TerminalManagerService,
  terminalId: string,
  options: {
    readonly lastOutputSeq: number
    readonly protocol: number
    readonly flowControl?: { readonly highWater: number; readonly lowWater: number }
  },
  webSocket: WebSocket
): Promise<void> => {
  let disconnect: (() => void) | undefined
  let deferredResync: number | undefined
  const subscribed = (unsubscribe: () => void): void => {
    disconnect = unsubscribe
    if (deferredResync === undefined) return
    const fromSeq = deferredResync
    deferredResync = undefined
    resubscribe(fromSeq)
  }
  const resubscribe = (fromSeq: number): void => {
    /* v8 ignore next */
    if (webSocket.readyState !== WebSocket.OPEN) return
    if (disconnect === undefined) {
      deferredResync = fromSeq
      return
    }
    disconnect()
    disconnect = undefined
    run(terminal.connectTerminal(terminalId, fromSeq, sink)).then(
      subscribed,
      /* v8 ignore next */
      () => webSocket.close()
    )
  }
  const clientIds = new Set<string>()
  const sink = (frame: TerminalServerFrame): void => {
    /* v8 ignore next */
    if (webSocket.readyState === WebSocket.OPEN) sender.sink(frame)
  }
  const sender: TerminalSocketSender = new TerminalSocketSender(webSocket, {
    binary: options.protocol >= 2,
    lastOutputSeq: options.lastOutputSeq,
    ...options.flowControl,
    resync: resubscribe
  })
  if (options.protocol >= 2) webSocket.send(JSON.stringify({ type: "ready", seq: 0, protocol: 2 }))
  try {
    subscribed(await run(terminal.connectTerminal(terminalId, options.lastOutputSeq, sink)))
  } catch (cause) {
    sendError(webSocket, cause)
    webSocket.close()
    return
  }
  const handlePing = (message: unknown): boolean => {
    if (
      !(
        typeof message === "object" &&
        message !== null &&
        "type" in message &&
        message.type === "ping"
      )
    )
      return false
    try {
      const ping = decode(TerminalPingFrame)(message)
      if (ping.srtt !== undefined) sender.setRoundTrip(ping.srtt)
      webSocket.send(JSON.stringify({ type: "pong", seq: 0, t: ping.t }))
    } catch (cause) {
      sendError(webSocket, cause)
    }
    return true
  }
  webSocket.on("message", (data: Buffer) => {
    let message: unknown
    try {
      message = JSON.parse(data.toString())
    } catch (cause) {
      sendError(webSocket, cause)
      return
    }
    if (handlePing(message)) return
    let frame: TerminalClientFrame
    try {
      frame = decode(TerminalClientFrame)(message)
    } catch (cause) {
      sendError(webSocket, cause)
      return
    }
    if (!clientIds.has(frame.clientId)) {
      clientIds.add(frame.clientId)
      const key = `${terminalId}\u0000${frame.clientId}`
      openSockets.set(key, (openSockets.get(key) ?? 0) + 1)
    }
    void run(terminal.handleClientFrame(terminalId, frame))
      .catch((cause: unknown) => sendError(webSocket, cause))
      .finally(() => {
        if (options.protocol >= 2 && webSocket.readyState === WebSocket.OPEN) {
          webSocket.send(JSON.stringify({ type: "ack", seq: 0, clientSeq: frame.clientSeq }))
        }
      })
  })
  webSocket.on("close", () => {
    disconnect?.()
    for (const clientId of clientIds) {
      const key = `${terminalId}\u0000${clientId}`
      const remaining = openSockets.get(key)! - 1
      if (remaining > 0) {
        openSockets.set(key, remaining)
        continue
      }
      openSockets.delete(key)
      terminal.releaseClient(terminalId, clientId)
    }
  })
}
