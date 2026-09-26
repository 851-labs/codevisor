import { randomUUID } from "node:crypto"

import {
  ClientControlFrame,
  decode,
  type ClientContext,
  type ClientControlCommand,
  type ClientSummary,
  type ConnectedClient
} from "@codevisor/api"
import type { WebSocket } from "ws"

import { HttpFailure } from "../server-context.js"

interface Pending {
  readonly resolve: (context: ClientContext) => void
  readonly reject: (error: Error) => void
  readonly timer: ReturnType<typeof setTimeout>
}
interface Connection {
  readonly socket: WebSocket
  readonly pending: Map<string, Pending>
  hello?: ConnectedClient
  handshakeTimer?: ReturnType<typeof setTimeout>
  lastActiveAt?: string
}

/// How long `clients.list` waits for each window's context before listing it
/// without one.
export const CLIENT_LIST_CONTEXT_TIMEOUT_MS = 1_500

export type ClientUnavailablePhase = "before-send" | "in-flight"

/// The addressed window is not attached (`before-send`), or it went away
/// while a command awaited its acknowledgement (`in-flight`, outcome
/// unknown). Serialized with code `client_unavailable` so gateway scripts can
/// raise a typed `ClientUnavailableError`.
const clientUnavailable = (
  status: number,
  message: string,
  clientId: string,
  name: string | undefined,
  phase: ClientUnavailablePhase
): HttpFailure =>
  new HttpFailure(status, message, "client_unavailable", {
    clientId,
    ...(name === undefined ? {} : { name }),
    phase
  })

/// Ephemeral, explicitly addressed native windows. Commands are never stored
/// or replayed after reconnect: a timed-out navigation has an unknown outcome.
export class ClientControlBroker {
  private readonly connections = new Map<string, Connection>()

  constructor(private readonly timeoutMs = 10_000) {}

  list(): ReadonlyArray<ConnectedClient> {
    return [...this.connections.values()].flatMap((connection) =>
      connection.hello ? [connection.hello] : []
    )
  }

  /// Every attached window with what it is viewing. Contexts are requested in
  /// parallel; a window that does not answer within `contextTimeoutMs` is
  /// still listed (it stays attached), just without `viewing`.
  async describe(
    machine: { readonly id: string; readonly name: string },
    originClientId: string | null,
    contextTimeoutMs = CLIENT_LIST_CONTEXT_TIMEOUT_MS
  ): Promise<ReadonlyArray<ClientSummary>> {
    const origin = originClientId?.toLowerCase()
    return Promise.all(
      this.list().map(async (client): Promise<ClientSummary> => {
        const context = await this.request(
          client.clientId,
          { method: "context" },
          { timeoutMs: contextTimeoutMs, keepOnTimeout: true }
        ).catch(() => undefined)
        const lastActiveAt = this.connections.get(client.clientId)?.lastActiveAt
        return {
          id: client.clientId,
          clientId: client.clientId,
          name: client.name,
          platform: client.platform,
          machine: { id: machine.id, name: machine.name },
          online: true,
          ...(origin === undefined ? {} : { isOrigin: client.clientId.toLowerCase() === origin }),
          ...(context === undefined ? {} : { isActive: context.isActive }),
          ...(lastActiveAt === undefined ? {} : { lastActiveAt }),
          ...(context === undefined ? {} : { viewing: viewingOf(context) }),
          ...(context?.capabilities === undefined ? {} : { capabilities: context.capabilities })
        }
      })
    )
  }

  attach(clientId: string, socket: WebSocket): void {
    this.disconnect(clientId)
    const connection: Connection = { socket, pending: new Map() }
    this.connections.set(clientId, connection)
    const handshakeTimer = setTimeout(() => this.disconnect(clientId), this.timeoutMs)
    handshakeTimer.unref()
    connection.handshakeTimer = handshakeTimer
    socket.on("close", () => {
      clearTimeout(handshakeTimer)
      if (this.connections.get(clientId) === connection) this.disconnect(clientId)
    })
    socket.on("error", () => {
      if (this.connections.get(clientId) === connection) this.disconnect(clientId)
    })
    socket.on("message", (data) => {
      if (this.connections.get(clientId) !== connection) return
      try {
        const frame = decode(ClientControlFrame)(JSON.parse(data.toString()))
        if (frame.type === "hello") {
          connection.hello = { clientId, name: frame.name, platform: frame.platform }
          clearTimeout(handshakeTimer)
          return
        }
        const pending = connection.pending.get(frame.requestId)
        if (!pending) return
        clearTimeout(pending.timer)
        connection.pending.delete(frame.requestId)
        if (frame.context?.isActive === true) connection.lastActiveAt = new Date().toISOString()
        if (frame.error !== undefined) pending.reject(new HttpFailure(409, frame.error))
        else if (frame.context !== undefined) pending.resolve(lowercaseIds(frame.context))
        else pending.reject(new HttpFailure(502, "Client returned no context"))
      } catch {
        this.disconnect(clientId)
      }
    })
  }

  /// Sends one command. `keepOnTimeout` is for read-only probes: a window
  /// that is merely slow stays attached, whereas an unacknowledged mutation
  /// detaches it because its outcome is unknown.
  request(
    clientId: string,
    command: Omit<ClientControlCommand, "requestId">,
    options: { readonly timeoutMs?: number; readonly keepOnTimeout?: boolean } = {}
  ): Promise<ClientContext> {
    const connection = this.connections.get(clientId)
    if (!connection?.hello)
      return Promise.reject(
        clientUnavailable(
          404,
          "Client is not connected. Discover clients again.",
          clientId,
          undefined,
          "before-send"
        )
      )
    return new Promise((resolve, reject) => {
      const requestId = randomUUID()
      const timer = setTimeout(() => {
        connection.pending.delete(requestId)
        reject(
          new HttpFailure(
            504,
            "Client did not acknowledge the command; its outcome is unknown. Read client context before retrying."
          )
        )
        if (options.keepOnTimeout !== true) this.disconnect(clientId)
      }, options.timeoutMs ?? this.timeoutMs)
      timer.unref()
      connection.pending.set(requestId, { resolve, reject, timer })
      socketSend(connection, { ...command, requestId }, () => this.disconnect(clientId))
    })
  }

  private disconnect(clientId: string): void {
    const connection = this.connections.get(clientId)
    if (!connection) return
    this.connections.delete(clientId)
    clearTimeout(connection.handshakeTimer)
    for (const pending of connection.pending.values()) {
      clearTimeout(pending.timer)
      pending.reject(
        clientUnavailable(
          503,
          "Client disconnected before acknowledging the command; its outcome is unknown.",
          clientId,
          // Only acknowledged windows (past hello) ever have pending commands.
          connection.hello!.name,
          "in-flight"
        )
      )
    }
    connection.pending.clear()
    connection.socket.close()
  }

  close(): void {
    for (const clientId of this.connections.keys()) this.disconnect(clientId)
  }
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

/// Native clients report Foundation UUIDs in uppercase; the server's ids are
/// lowercase. Normalize id fields so agents can compare a window's context
/// with session and workspace ids directly.
const lowercaseIds = <T>(value: T, key = ""): T => {
  if (Array.isArray(value)) return value.map((item) => lowercaseIds(item, key)) as T
  if (value !== null && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).map(([field, item]) => [field, lowercaseIds(item, field)])
    ) as T
  }
  const isIdField = key === "id" || key.endsWith("Id")
  return (
    isIdField && typeof value === "string" && UUID.test(value) ? value.toLowerCase() : value
  ) as T
}

const viewingOf = (context: ClientContext): NonNullable<ClientSummary["viewing"]> => {
  const workspace = context.workspaces.find((candidate) => candidate.id === context.workspaceId)
  const tab = workspace?.tabs.find((candidate) => candidate.id === workspace.tabId)
  return {
    ...(context.workspaceId === undefined ? {} : { workspaceId: context.workspaceId }),
    ...(workspace?.sessionId === undefined ? {} : { sessionId: workspace.sessionId }),
    ...(context.page === undefined ? {} : { page: context.page.page }),
    ...(tab === undefined ? {} : { panes: tab.panes })
  }
}

const socketSend = (
  connection: Connection,
  command: ClientControlCommand,
  failed: () => void
): void => {
  try {
    connection.socket.send(JSON.stringify(command), (error) => {
      if (error) failed()
    })
  } catch {
    failed()
  }
}
