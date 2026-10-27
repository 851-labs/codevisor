import type { IncomingMessage, ServerResponse } from "node:http"
import type { Socket } from "node:net"

import { decode } from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"
import { Schema } from "effect"
import type { WebSocketServer } from "ws"

import type { ClientControlBroker } from "../infra/client-control.js"
import {
  authorize,
  parseRequestUrl,
  type CodevisorServerConfig,
  type CodevisorServerServices,
  type EventFanout
} from "../server-context.js"
import { attachSyncEventSocket, type SyncEventSink } from "./sync-event-socket.js"
import {
  acceptAuthorizedSocket,
  acceptPublicSocket,
  type SocketUpgrade
} from "./upgrade-sockets.js"

export { attachEventSocket } from "./upgrade-sockets.js"

export const handleEvents = async (
  db: CodevisorDatabaseService,
  fanout: EventFanout,
  url: URL,
  response: ServerResponse
): Promise<void> => {
  const since = Number(url.searchParams.get("since") ?? "0")
  response.writeHead(200, {
    "Cache-Control": "no-cache",
    Connection: "keep-alive",
    "Content-Type": "text/event-stream"
  })
  await attachSyncEventSocket(
    db,
    fanout,
    Number.isFinite(since) ? since : 0,
    sseSocket(response),
    ""
  )
}

export const handleUpgrade = async (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  fanout: EventFanout,
  request: IncomingMessage,
  socket: Socket,
  head: Buffer,
  webSocketServer: WebSocketServer,
  clientControl?: ClientControlBroker
): Promise<void> => {
  socket.on("error", () => socket.destroy())
  const upgrade: SocketUpgrade = {
    services,
    config,
    fanout,
    request,
    socket,
    head,
    webSocketServer,
    clientControl
  }
  try {
    const url = parseRequestUrl(request)
    if (acceptPublicSocket(upgrade, url)) return

    await authorize(services.db, config, request)
    acceptAuthorizedSocket(upgrade, url)
  } catch {
    refuseUnauthorized(socket)
  }
}

const refuseUnauthorized = (socket: Socket): void => {
  socket.write("HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n")
  socket.destroy()
}

const sseSocket = (response: ServerResponse): SyncEventSink => ({
  get bufferedAmount() {
    return response.writableLength
  },
  send(data) {
    writeSse(response, data)
  },
  close() {
    response.end()
  },
  on(_event, listener) {
    return response.on("close", listener)
  }
})

const SseFrame = Schema.Struct({ id: Schema.Number, kind: Schema.String })

const writeSse = (response: ServerResponse, data: string): void => {
  const event = decode(SseFrame)(JSON.parse(data))
  response.write(`id: ${event.id}\n`)
  response.write(`event: ${event.kind}\n`)
  response.write(`data: ${data}\n\n`)
}
