import type { IncomingMessage, ServerResponse } from "node:http"
import type { Socket } from "node:net"

import type { EventEnvelope, TerminalClientFrame } from "@codevisor/api"
import { TerminalClientFrame as TerminalClientFrameSchema, decode } from "@codevisor/api"
import { CODEVISOR_BROWSER_EXTENSION_ID } from "@codevisor/automation"
import type { CodevisorDatabaseService } from "@codevisor/db"
import type { TerminalManagerService } from "@codevisor/terminal"
import { WebSocket, type WebSocketServer } from "ws"

import type { ClientControlBroker } from "../infra/client-control.js"
import {
  authorize,
  failureMessage,
  HttpFailure,
  isLocalhost,
  matchRoute,
  parseRequestUrl,
  run,
  type CodevisorServerConfig,
  type CodevisorServerServices,
  type EventFanout
} from "../server-context.js"
import { adaptDirectSocket } from "./net-direct.js"
import { spliceVNCSocket, VNC_SOCKET_PATH } from "./screen-sharing-vnc.js"
import { attachSyncEventSocket } from "./sync-event-socket.js"

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
    {
      get bufferedAmount() {
        return response.writableLength
      },
      send(data) {
        writeSse(response, JSON.parse(data) as EventEnvelope)
      },
      close() {
        response.end()
      },
      on(_event, listener) {
        return response.on("close", listener)
      }
    },
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
  try {
    const url = parseRequestUrl(request)
    if (
      request.method === "GET" &&
      url.pathname === "/v1/browser-use/extension/socket" &&
      services.mcp !== undefined &&
      isLocalhost(request.socket.remoteAddress) &&
      request.headers.origin === `chrome-extension://${CODEVISOR_BROWSER_EXTENSION_ID}`
    ) {
      webSocketServer.handleUpgrade(request, socket, head, (webSocket) => {
        services.mcp!.acceptBrowserExtension(webSocket)
      })
      return
    }
    // Direct sealed-channel pipe: authenticates via already-pinned E2E
    // identity inside the channel protocol itself (DirectChannelHost) — a
    // bearer token would be both unnecessary and unavailable to it.
    if (
      request.method === "GET" &&
      url.pathname === "/v1/direct" &&
      config.directPathEnabled &&
      config.cloud?.acceptDirect !== undefined
    ) {
      const acceptDirect = config.cloud.acceptDirect
      webSocketServer.handleUpgrade(request, socket, head, (webSocket) => {
        if (!acceptDirect(adaptDirectSocket(webSocket))) {
          webSocket.close(1013, "no cloud identity to serve direct connections")
        }
      })
      return
    }
    // Plugin pane WebSockets authenticate inside the proxy (pane token,
    // session cookie, or loopback for relayed traffic) — never with the
    // machine bearer token, which webviews cannot attach.
    if (
      url.pathname.startsWith("/v1/plugins/") &&
      services.plugins !== undefined &&
      (await services.plugins.handleUpgrade(request, socket, head))
    ) {
      return
    }
    await authorize(services.db, config, request)
    if (
      request.method === "GET" &&
      url.pathname === VNC_SOCKET_PATH &&
      config.screenSharingVNC !== undefined
    ) {
      spliceVNCSocket(config.screenSharingVNC, url, request, socket, head, webSocketServer)
      return
    }
    const clientId = matchRoute(url.pathname, "/v1/clients/:id/socket")
    if (request.method === "GET" && clientId !== undefined && clientControl !== undefined) {
      webSocketServer.handleUpgrade(request, socket, head, (webSocket) => {
        clientControl.attach(clientId, webSocket)
      })
      return
    }
    if (request.method === "GET" && url.pathname === "/v1/events/socket") {
      webSocketServer.handleUpgrade(request, socket, head, (webSocket) => {
        void attachEventSocket(
          services.db,
          fanout,
          numberSearchParam(url, "since"),
          webSocket,
          config.id,
          undefined,
          EVENT_SOCKET_KEEPALIVE_MS,
          url.searchParams.get("sync") === "1"
        ).catch(
          /* v8 ignore next -- defensive: socket setup failures close the just-upgraded connection. */
          () => webSocket.close()
        )
      })
      return
    }

    const sessionEventId = matchRoute(url.pathname, "/v1/sessions/:id/events/socket")
    if (request.method === "GET" && sessionEventId !== undefined) {
      webSocketServer.handleUpgrade(request, socket, head, (webSocket) => {
        void attachEventSocket(
          services.db,
          fanout,
          numberSearchParam(url, "since"),
          webSocket,
          config.id,
          sessionEventId,
          EVENT_SOCKET_KEEPALIVE_MS,
          url.searchParams.get("sync") === "1"
        ).catch(
          /* v8 ignore next -- defensive: socket setup failures close the just-upgraded connection. */
          () => webSocket.close()
        )
      })
      return
    }

    const terminalId = matchRoute(url.pathname, "/v1/terminals/:id/socket")
    if (terminalId === undefined) {
      socket.destroy()
      return
    }

    webSocketServer.handleUpgrade(request, socket, head, (webSocket) => {
      void attachTerminalSocket(
        services.terminal,
        terminalId,
        numberSearchParam(url, "lastOutputSeq"),
        webSocket
      ).catch(
        /* v8 ignore next -- defensive: socket setup failures close the just-upgraded connection. */
        () => webSocket.close()
      )
    })
  } catch {
    socket.write("HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n")
    socket.destroy()
  }
}

/// Keepalives let quiet clients detect dead paths without advancing their
/// replay cursor. Global and session subscribers share the bounded journal reader.
const EVENT_SOCKET_KEEPALIVE_MS = 25_000

export const attachEventSocket = async (
  db: CodevisorDatabaseService,
  fanout: EventFanout,
  since: number,
  webSocket: WebSocket,
  serverId: string,
  subjectId?: string,
  keepaliveMs: number = EVENT_SOCKET_KEEPALIVE_MS,
  _durableReplay: boolean = false
): Promise<void> =>
  attachSyncEventSocket(db, fanout, since, webSocket, serverId, subjectId, keepaliveMs)

const attachTerminalSocket = async (
  terminal: TerminalManagerService,
  terminalId: string,
  lastOutputSeq: number,
  webSocket: WebSocket
): Promise<void> => {
  try {
    const disconnect = await run(
      terminal.connectTerminal(terminalId, lastOutputSeq, (frame) => {
        /* v8 ignore next -- the close event removes this sink before normal closed-socket output. */
        if (webSocket.readyState === WebSocket.OPEN) {
          webSocket.send(JSON.stringify(frame))
        }
      })
    )
    webSocket.on("message", (data) => {
      const frame = parseTerminalFrameOrSend(data.toString(), webSocket)
      if (frame === undefined) {
        return
      }
      void run(terminal.handleClientFrame(terminalId, frame)).catch((cause: unknown) => {
        webSocket.send(JSON.stringify({ type: "error", seq: 0, message: failureMessage(cause) }))
      })
    })
    webSocket.on("close", disconnect)
  } catch (cause) {
    webSocket.send(JSON.stringify({ type: "error", seq: 0, message: failureMessage(cause) }))
    webSocket.close()
  }
}

const parseTerminalFrame = (raw: string): TerminalClientFrame => {
  try {
    return decode(TerminalClientFrameSchema)(JSON.parse(raw) as unknown)
  } catch (cause) {
    throw new HttpFailure(400, failureMessage(cause))
  }
}

const parseTerminalFrameOrSend = (
  raw: string,
  webSocket: WebSocket
): TerminalClientFrame | undefined => {
  try {
    return parseTerminalFrame(raw)
  } catch (cause) {
    webSocket.send(JSON.stringify({ type: "error", seq: 0, message: failureMessage(cause) }))
    return undefined
  }
}

const numberSearchParam = (url: URL, name: string): number => {
  const parsed = Number(url.searchParams.get(name) ?? "0")
  return Number.isFinite(parsed) && parsed > 0 ? parsed : 0
}

const writeSse = (response: ServerResponse, event: EventEnvelope): void => {
  response.write(`id: ${event.id}\n`)
  response.write(`event: ${event.kind}\n`)
  response.write(`data: ${JSON.stringify(event)}\n\n`)
}
