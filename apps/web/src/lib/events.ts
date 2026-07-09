// The live event feed: a WebSocket to /v1/events/socket with the Swift
// client's reconnect semantics — exponential backoff with jitter, resuming
// from the last seen cursor (`?since=`). The server replays persisted events
// past the cursor on reconnect, so subscribers never miss events.
import { decode, EventEnvelope } from "@herdman/api"

import type { ServerConfig } from "./server-config"

const decodeEnvelope = decode(EventEnvelope)

type EventListener = (event: EventEnvelope) => void

function reconnectDelayMs(failures: number): number {
  const base = Math.min(5000, 250 * 2 ** Math.min(failures, 5))
  return base + Math.floor(Math.random() * 251)
}

export class EventSocket {
  private readonly config: ServerConfig
  private readonly listeners = new Set<EventListener>()
  private socket: WebSocket | undefined
  private reconnectTimer: ReturnType<typeof setTimeout> | undefined
  private failures = 0
  private stopped = true
  cursor: number

  constructor(config: ServerConfig, options: { since?: number } = {}) {
    this.config = config
    this.cursor = options.since ?? 0
  }

  start(): void {
    if (!this.stopped) return
    this.stopped = false
    this.connect()
  }

  stop(): void {
    this.stopped = true
    if (this.reconnectTimer != null) {
      clearTimeout(this.reconnectTimer)
      this.reconnectTimer = undefined
    }
    this.socket?.close()
    this.socket = undefined
  }

  subscribe(listener: EventListener): () => void {
    this.listeners.add(listener)
    return () => {
      this.listeners.delete(listener)
    }
  }

  private connect(): void {
    if (this.stopped) return
    // Browser WebSockets can't set Authorization headers; loopback and
    // same-origin connections are auth-exempt, so the token (remote servers
    // only) rides a query parameter when present.
    const token = this.config.token != null ? `&token=${encodeURIComponent(this.config.token)}` : ""
    const url = `${this.config.wsBaseUrl}/v1/events/socket?since=${this.cursor}${token}`
    const socket = new WebSocket(url)
    this.socket = socket

    socket.onopen = () => {
      this.failures = 0
    }
    socket.onmessage = (message) => {
      let event: EventEnvelope
      try {
        event = decodeEnvelope(JSON.parse(String(message.data)))
      } catch {
        return
      }
      this.cursor = Math.max(this.cursor, event.id)
      for (const listener of this.listeners) listener(event)
    }
    socket.onclose = () => {
      if (this.socket === socket) this.scheduleReconnect()
    }
    socket.onerror = () => {
      socket.close()
    }
  }

  private scheduleReconnect(): void {
    if (this.stopped) return
    this.failures += 1
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = undefined
      this.connect()
    }, reconnectDelayMs(this.failures))
  }
}
