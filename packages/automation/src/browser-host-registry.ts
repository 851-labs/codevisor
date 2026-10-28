import { randomUUID } from "node:crypto"
import { EventEmitter } from "node:events"

import { WebSocket } from "ws"

import type { NativeBrowserHost } from "./browser-cdp-engine.js"
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

export type BrowserHostAnswer =
  | "focused"
  | "showing"
  | "available"
  | "unavailable"
  | "unresponsive"
  | "disconnected"

export interface BrowserHostProbe {
  readonly host: BrowserHostSummary
  readonly answer: BrowserHostAnswer
}

export interface ConnectedBrowserHost {
  readonly connection: CdpConnection
  readonly host: BrowserHostSummary
  readonly showing: boolean
  readonly probes: ReadonlyArray<BrowserHostProbe>
}

export type BrowserHostConnection =
  | (ConnectedBrowserHost & { readonly reason?: never })
  | {
      readonly connection?: never
      readonly host?: never
      readonly reason: string
      readonly probes: ReadonlyArray<BrowserHostProbe>
    }

export interface BrowserHostRegistry {
  readonly accept: (socket: BrowserHostSocket) => void
  readonly hosts: () => ReadonlyArray<BrowserHostSummary>
  readonly lostHost: (sessionId: string) => string | undefined
  readonly probe: (sessionId: string) => Promise<ReadonlyArray<BrowserHostProbe>>
  readonly connect: (sessionId: string) => Promise<BrowserHostConnection>
  readonly forgetSession: (sessionId: string) => void
  readonly close: () => void
}

export const browserHostAnswerReason = ({ host, answer }: BrowserHostProbe): string => {
  if (answer === "unresponsive")
    return `The Codevisor app on ${host.name} did not respond. Check that Mac for a blocking dialog.`
  if (answer === "disconnected") return `The Codevisor app on ${host.name} disconnected.`
  return `The Codevisor app on ${host.name} can't open this chat.`
}

export const noBrowserHostReason = "No Codevisor Mac app is connected to this server."

export const chosenBrowserHost = (
  probes: ReadonlyArray<BrowserHostProbe>
): NativeBrowserHost | undefined => {
  const [best] = probes
  if (best === undefined) return undefined
  return answeringHost(best)
}

export const probedBrowserHost = (
  probes: ReadonlyArray<BrowserHostProbe>,
  hostId: string
): NativeBrowserHost | undefined => {
  const probe = probes.find(({ host }) => host.id === hostId)
  if (probe === undefined) return undefined
  return answeringHost(probe)
}

export const unreachableBrowserHostReason = (probes: ReadonlyArray<BrowserHostProbe>): string => {
  if (probes.length === 0) return noBrowserHostReason
  return probes.map(browserHostAnswerReason).join(" ")
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

  const ask = async (host: Host, sessionId: string): Promise<HostReply> => {
    const connection = openChannel(host, sessionId)
    try {
      const result = await connection.send<ConnectReply>(
        "Codevisor.connect",
        { sessionId },
        undefined,
        BROWSER_HOST_HANDSHAKE_MS
      )
      const answer = connectAnswer(result)
      if (answer !== "unavailable") return { host: summary(host), answer, connection }

      await connection.close()
      return { host: summary(host), answer }
    } catch (cause) {
      await connection.close()
      return { host: summary(host), answer: failureAnswer(cause) }
    }
  }

  const askAll = (sessionId: string): Promise<ReadonlyArray<HostReply>> =>
    Promise.all([...hosts.values()].map((host) => ask(host, sessionId)))

  const probe = async (sessionId: string): Promise<ReadonlyArray<BrowserHostProbe>> => {
    const replies = rank(await askAll(sessionId), sessionHosts.get(sessionId))
    await closeReplies(replies)
    return replies.map(probeOf)
  }

  const connect = async (sessionId: string): Promise<BrowserHostConnection> => {
    const replies = rank(await askAll(sessionId), sessionHosts.get(sessionId))
    const [chosen] = replies
    await closeReplies(replies.slice(1))
    const probes = replies.map(probeOf)
    if (chosen?.connection === undefined)
      return { reason: unreachableBrowserHostReason(probes), probes }

    sessionHosts.set(sessionId, chosen.host.id)
    lostHosts.delete(sessionId)
    return {
      connection: chosen.connection,
      host: chosen.host,
      showing: chosen.answer !== "available",
      probes
    }
  }

  const openChannel = (host: Host, sessionId: string): CdpConnection => {
    const channelId = randomUUID()
    const channel = new BrowserHostChannel(host, channelId)
    host.channels.set(channelId, channel)
    host.socket.send(JSON.stringify({ type: "open", channel: channelId, sessionId }))
    return CdpConnection.fromSocket(channel)
  }

  return {
    accept,
    hosts: () => [...hosts.values()].map(summary),
    lostHost: (sessionId) => lostHosts.get(sessionId),
    probe,
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

interface ConnectReply {
  readonly available?: boolean
  readonly showing?: boolean
  readonly focused?: boolean
}

interface HostReply extends BrowserHostProbe {
  readonly connection?: CdpConnection
}

const answerRanks: Record<BrowserHostAnswer, number> = {
  focused: 3,
  showing: 2,
  available: 1,
  unavailable: 0,
  unresponsive: 0,
  disconnected: 0
}

const connectAnswer = (reply: ConnectReply): BrowserHostAnswer => {
  if (reply.available !== true) return "unavailable"
  if (reply.focused === true) return "focused"
  return reply.showing === true ? "showing" : "available"
}

const failureAnswer = (cause: unknown): BrowserHostAnswer =>
  /timed out/i.test(String(cause)) ? "unresponsive" : "disconnected"

const rank = (replies: ReadonlyArray<HostReply>, stickyHostId: string | undefined) =>
  replies.toSorted(
    (left, right) =>
      answerRanks[right.answer] - answerRanks[left.answer] ||
      Number(right.host.id === stickyHostId) - Number(left.host.id === stickyHostId) ||
      right.host.lastActiveAt - left.host.lastActiveAt
  )

const closeReplies = async (replies: ReadonlyArray<HostReply>): Promise<void> => {
  const open = replies.flatMap(({ connection }) => (connection === undefined ? [] : [connection]))
  await Promise.all(open.map((connection) => connection.close()))
}

const answeringHost = ({ host, answer }: BrowserHostProbe): NativeBrowserHost | undefined => {
  if (answerRanks[answer] === 0) return undefined
  return { id: host.id, name: host.name, showing: answer !== "available" }
}

const probeOf = ({ host, answer }: HostReply): BrowserHostProbe => ({ host, answer })
