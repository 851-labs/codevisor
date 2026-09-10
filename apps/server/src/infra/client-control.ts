import {
  ClientControlFrame,
  decode,
  type ClientContext,
  type ClientControlCommand,
  type ConnectedClient
} from "@codevisor/api"
import { randomUUID } from "node:crypto"
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
}

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
        if (frame.error !== undefined) pending.reject(new HttpFailure(409, frame.error))
        else if (frame.context !== undefined) pending.resolve(frame.context)
        else pending.reject(new HttpFailure(502, "Client returned no context"))
      } catch {
        this.disconnect(clientId)
      }
    })
  }

  request(
    clientId: string,
    command: Omit<ClientControlCommand, "requestId">
  ): Promise<ClientContext> {
    const connection = this.connections.get(clientId)
    if (!connection?.hello)
      return Promise.reject(
        new HttpFailure(404, "Client is not connected. Discover clients again.")
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
        this.disconnect(clientId)
      }, this.timeoutMs)
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
        new HttpFailure(
          503,
          "Client disconnected before acknowledging the command; its outcome is unknown."
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
