import { randomUUID } from "node:crypto"
import { EventEmitter } from "node:events"

import { WebSocket } from "ws"

import { CdpConnection, type CdpSocket } from "./browser-cdp.js"
import { recordOrEmpty } from "./unknown-values.js"

export const BROWSER_HOST_HANDSHAKE_MS = 5_000

export interface BrowserHostSocket {
  readonly readyState: number
  on(event: "message", listener: (data: Buffer | string) => void): unknown
  on(event: "close", listener: () => void): unknown
  send(data: string): void
  close(code?: number, reason?: string): void
}

export interface BrowserHostSummary {
  readonly id: string
  readonly name: string
  readonly lastActiveAt: number
}

export type BrowserHostConnection =
  | {
      readonly connection: CdpConnection
      readonly host: BrowserHostSummary
      readonly reason?: never
    }
  | { readonly connection?: never; readonly host?: never; readonly reason: string }

export interface BrowserHostState {
  readonly host?: BrowserHostSummary
  readonly lostHost?: string
}

export interface BrowserHostRegistry {
  readonly accept: (socket: BrowserHostSocket) => void
  readonly hosts: () => ReadonlyArray<BrowserHostSummary>
  readonly state: (sessionId: string) => BrowserHostState
  readonly connect: (sessionId: string) => Promise<BrowserHostConnection>
  readonly forgetSession: (sessionId: string) => void
  readonly close: () => void
}

interface Host {
  readonly id: string
  readonly name: string
  readonly socket: BrowserHostSocket
  readonly channels: Map<string, BrowserHostChannel>
  lastActiveAt: number
}

class BrowserHostChannel extends EventEmitter implements CdpSocket {
  readyState: number = WebSocket.OPEN

  constructor(
    private readonly host: Host,
    readonly channel: string
  ) {
    super()
  }

  send(message: string): void {
    this.host.socket.send(`${JSON.stringify({ type: "data", channel: this.channel })}\n${message}`)
  }

  deliver(message: string): void {
    this.emit("message", Buffer.from(message))
  }

  close(): void {
    this.host.socket.send(JSON.stringify({ type: "close", channel: this.channel }))
    this.ended()
  }

  terminate(): void {
    this.close()
  }

  ended(): void {
    this.readyState = WebSocket.CLOSED
    this.host.channels.delete(this.channel)
    this.emit("close")
  }
}

const frame = (data: Buffer | string): { header: Record<string, unknown>; body: string } => {
  const text = String(data)
  const newline = text.indexOf("\n")
  const header = newline === -1 ? text : text.slice(0, newline)
  try {
    return {
      header: recordOrEmpty(JSON.parse(header)),
      body: newline === -1 ? "" : text.slice(newline + 1)
    }
  } catch {
    return { header: {}, body: "" }
  }
}

const summary = (host: Host): BrowserHostSummary => ({
  id: host.id,
  name: host.name,
  lastActiveAt: host.lastActiveAt
})

export const makeBrowserHostRegistry = (now: () => number = Date.now): BrowserHostRegistry => {
  const hosts = new Map<string, Host>()
  const sessionHosts = new Map<string, string>()
  const lostHosts = new Map<string, string>()

  const remove = (host: Host) => {
    if (hosts.get(host.id) !== host) return
    hosts.delete(host.id)
    for (const channel of host.channels.values()) channel.ended()
    for (const [sessionId, hostId] of sessionHosts) {
      if (hostId !== host.id) continue
      sessionHosts.delete(sessionId)
      lostHosts.set(sessionId, host.name)
    }
  }

  const accept = (socket: BrowserHostSocket) => {
    let host: Host | undefined
    const handshake = setTimeout(
      () => socket.close(1008, "Browser host did not introduce itself"),
      BROWSER_HOST_HANDSHAKE_MS
    )
    handshake.unref()
    socket.on("message", (data) => {
      const { header, body } = frame(data)
      if (host === undefined) {
        if (header.type !== "hello" || typeof header.hostId !== "string") {
          socket.close(1008, "Expected a browser host hello")
          return
        }
        clearTimeout(handshake)
        const id = header.hostId
        const existing = hosts.get(id)
        if (existing !== undefined) remove(existing)
        host = {
          id,
          name: typeof header.name === "string" && header.name !== "" ? header.name : "Mac",
          socket,
          channels: new Map(),
          lastActiveAt: now() - (typeof header.idleMs === "number" ? Math.max(0, header.idleMs) : 0)
        }
        hosts.set(id, host)
        return
      }
      if (header.type === "activity") host.lastActiveAt = now()
      else if (header.type === "data" && typeof header.channel === "string")
        host.channels.get(header.channel)?.deliver(body)
      else if (header.type === "close" && typeof header.channel === "string")
        host.channels.get(header.channel)?.ended()
    })
    socket.on("close", () => {
      clearTimeout(handshake)
      if (host !== undefined) remove(host)
    })
  }

  const mostRecentlyActive = (): Host | undefined =>
    [...hosts.values()].toSorted((left, right) => right.lastActiveAt - left.lastActiveAt)[0]

  const hostFor = (sessionId: string): Host | undefined => {
    const sticky = sessionHosts.get(sessionId)
    return (sticky === undefined ? undefined : hosts.get(sticky)) ?? mostRecentlyActive()
  }

  const state = (sessionId: string): BrowserHostState => {
    const host = hostFor(sessionId)
    const lostHost = lostHosts.get(sessionId)
    return {
      ...(host === undefined ? {} : { host: summary(host) }),
      ...(lostHost === undefined ? {} : { lostHost })
    }
  }

  const connect = async (sessionId: string): Promise<BrowserHostConnection> => {
    const host = hostFor(sessionId)
    if (host === undefined) return { reason: "No Codevisor Mac app is connected to this server." }
    const channelId = randomUUID()
    const channel = new BrowserHostChannel(host, channelId)
    host.channels.set(channelId, channel)
    host.socket.send(JSON.stringify({ type: "open", channel: channelId, sessionId }))
    const connection = CdpConnection.fromSocket(channel)
    try {
      const result = await connection.send<{ available?: boolean }>(
        "Codevisor.connect",
        { sessionId },
        undefined,
        BROWSER_HOST_HANDSHAKE_MS
      )
      if (result.available !== true) {
        await connection.close()
        return { reason: `The Codevisor app on ${host.name} can't open this chat.` }
      }
    } catch (cause) {
      await connection.close()
      return {
        reason: /timed out/i.test(String(cause))
          ? `The Codevisor app on ${host.name} did not respond. Check that Mac for a blocking dialog.`
          : `The Codevisor app on ${host.name} disconnected.`
      }
    }
    sessionHosts.set(sessionId, host.id)
    lostHosts.delete(sessionId)
    return { connection, host: summary(host) }
  }

  return {
    accept,
    hosts: () => [...hosts.values()].map(summary),
    state,
    connect,
    forgetSession: (sessionId) => {
      sessionHosts.delete(sessionId)
      lostHosts.delete(sessionId)
    },
    close: () => {
      for (const host of hosts.values()) {
        remove(host)
        host.socket.close(1001, "Codevisor server is closing")
      }
    }
  }
}
