// Terminal transport: POST /v1/terminals to create, then a WebSocket carrying
// JSON frames (TerminalClientFrame / TerminalServerFrame from @herdman/api).
// Reconnects resume from the last seen output sequence, which the server
// replays from its buffer.
import { decode, type TerminalClientFrame, TerminalServerFrame } from "@herdman/api"

import type { HerdManClient } from "./client"
import type { ServerConfig } from "./server-config"

const decodeServerFrame = decode(TerminalServerFrame)

export interface TerminalDelegate {
  onOutput(data: string): void
  onExit(exitCode: number | undefined): void
  onError(message: string): void
}

function reconnectDelayMs(failures: number): number {
  const base = Math.min(5000, 250 * 2 ** Math.min(failures, 5))
  return base + Math.floor(Math.random() * 251)
}

export class TerminalTransport {
  private readonly client: HerdManClient
  private readonly config: ServerConfig
  private readonly delegate: TerminalDelegate
  private readonly clientId = crypto.randomUUID()
  private clientSeq = 0
  private lastOutputSeq = 0
  private socket: WebSocket | undefined
  private websocketPath: string | undefined
  private reconnectTimer: ReturnType<typeof setTimeout> | undefined
  private failures = 0
  private closed = false

  constructor(client: HerdManClient, config: ServerConfig, delegate: TerminalDelegate) {
    this.client = client
    this.config = config
    this.delegate = delegate
  }

  async open(request: {
    sessionId: string
    cwd: string
    cols: number
    rows: number
    attachOnly?: boolean
  }): Promise<void> {
    const created = await this.client.createTerminal(request)
    this.websocketPath = created.websocketPath
    this.lastOutputSeq = Math.max(0, created.nextOutputSeq - 1)
    this.connect()
  }

  close(): void {
    this.closed = true
    if (this.reconnectTimer != null) clearTimeout(this.reconnectTimer)
    this.sendFrame({ type: "close", clientId: this.clientId, clientSeq: this.nextSeq() })
    this.socket?.close()
    this.socket = undefined
  }

  detach(): void {
    this.closed = true
    if (this.reconnectTimer != null) clearTimeout(this.reconnectTimer)
    this.socket?.close()
    this.socket = undefined
  }

  sendInput(data: string): void {
    this.sendFrame({ type: "input", data, clientId: this.clientId, clientSeq: this.nextSeq() })
  }

  sendResize(cols: number, rows: number): void {
    this.sendFrame({
      type: "resize",
      cols,
      rows,
      clientId: this.clientId,
      clientSeq: this.nextSeq()
    })
  }

  private nextSeq(): number {
    this.clientSeq += 1
    return this.clientSeq
  }

  private sendFrame(frame: TerminalClientFrame): void {
    if (this.socket?.readyState === WebSocket.OPEN) {
      this.socket.send(JSON.stringify(frame))
    }
  }

  private connect(): void {
    if (this.closed || this.websocketPath == null) return
    const token = this.config.token != null ? `&token=${encodeURIComponent(this.config.token)}` : ""
    const url = `${this.config.wsBaseUrl}${this.websocketPath}?lastOutputSeq=${this.lastOutputSeq}${token}`
    const socket = new WebSocket(url)
    this.socket = socket

    socket.onopen = () => {
      this.failures = 0
    }
    socket.onmessage = (message) => {
      let frame: TerminalServerFrame
      try {
        frame = decodeServerFrame(JSON.parse(String(message.data)))
      } catch {
        return
      }
      this.lastOutputSeq = Math.max(this.lastOutputSeq, frame.seq)
      switch (frame.type) {
        case "output":
          this.delegate.onOutput(frame.data)
          break
        case "exit":
          this.closed = true
          this.delegate.onExit(frame.exitCode)
          break
        case "error":
          this.delegate.onError(frame.message)
          break
      }
    }
    socket.onclose = () => {
      if (this.socket === socket && !this.closed) this.scheduleReconnect()
    }
    socket.onerror = () => {
      socket.close()
    }
  }

  private scheduleReconnect(): void {
    this.failures += 1
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = undefined
      this.connect()
    }, reconnectDelayMs(this.failures))
  }
}
