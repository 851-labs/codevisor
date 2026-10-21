import type { IncomingMessage, ServerResponse } from "node:http"
import type { Socket } from "node:net"

import { decode } from "@codevisor/api"
import { CODEVISOR_BROWSER_EXTENSION_ID } from "@codevisor/automation"
import type { CodevisorDatabaseService } from "@codevisor/db"
import { Schema } from "effect"
import { WebSocket, type WebSocketServer } from "ws"

import type { ClientControlBroker } from "../infra/client-control.js"
import {
  authorize,
  isLocalhost,
  matchRoute,
  parseRequestUrl,
  type CodevisorServerConfig,
  type CodevisorServerServices,
  type EventFanout
} from "../server-context.js"
import { attachLivePreviewSocket, LIVE_PREVIEW_SOCKET_PATH } from "./live-preview-socket.js"
import { adaptDirectSocket } from "./net-direct.js"
import { spliceVNCSocket, VNC_SOCKET_PATH } from "./screen-sharing-vnc.js"
import { attachSyncEventSocket } from "./sync-event-socket.js"
import { attachTerminalSocket } from "./terminal-socket.js"

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
        writeSse(response, data)
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
  socket.on("error", () => socket.destroy())
  const accept = (onSocket: (webSocket: WebSocket) => void): void => {
    webSocketServer.handleUpgrade(request, socket, head, (webSocket) => {
      webSocket.on("error", () => undefined)
      onSocket(webSocket)
    })
  }
  try {
    const url = parseRequestUrl(request)
    if (
      request.method === "GET" &&
      url.pathname === "/v1/browser-use/extension/socket" &&
      services.mcp !== undefined &&
      isLocalhost(request.socket.remoteAddress) &&
      request.headers.origin === `chrome-extension://${CODEVISOR_BROWSER_EXTENSION_ID}`
    ) {
      accept((webSocket) => {
        services.mcp!.acceptBrowserExtension(webSocket)
      })
      return
    }
    if (
      request.method === "GET" &&
      url.pathname === "/v1/direct" &&
      config.directPathEnabled &&
      config.cloud?.acceptDirect !== undefined
    ) {
      const acceptDirect = config.cloud.acceptDirect
      accept((webSocket) => {
        if (!acceptDirect(adaptDirectSocket(webSocket))) {
          webSocket.close(1013, "no cloud identity to serve direct connections")
        }
      })
      return
    }
    if (
      url.pathname.startsWith("/v1/plugins/") &&
      services.plugins !== undefined &&
      (await services.plugins.handleUpgrade(request, socket, head))
    ) {
      return
    }
    await authorize(services.db, config, request)
    const previewSession = url.searchParams.get("sessionId")
    if (
      request.method === "GET" &&
      url.pathname === LIVE_PREVIEW_SOCKET_PATH &&
      previewSession !== null &&
      services.mcp !== undefined
    ) {
      const mcp = services.mcp
      accept((webSocket) => attachLivePreviewSocket(mcp, previewSession, webSocket))
      return
    }
    if (
      request.method === "GET" &&
      url.pathname === VNC_SOCKET_PATH &&
      config.screenSharingVNC !== undefined
    ) {
      spliceVNCSocket(config.screenSharingVNC, url, request, socket, head, webSocketServer)
      return
    }
    if (
      request.method === "GET" &&
      url.pathname === "/v1/browser-use/host/socket" &&
      services.mcp !== undefined
    ) {
      const mcp = services.mcp
      accept((webSocket) => mcp.acceptBrowserHost(webSocket))
      return
    }
    const clientId = matchRoute(url.pathname, "/v1/clients/:id/socket")
    if (request.method === "GET" && clientId !== undefined && clientControl !== undefined) {
      accept((webSocket) => {
        clientControl.attach(clientId, webSocket)
      })
      return
    }
    if (request.method === "GET" && url.pathname === "/v1/events/socket") {
      accept((webSocket) => {
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
          /* v8 ignore next */
          () => webSocket.close()
        )
      })
      return
    }

    const sessionEventId = matchRoute(url.pathname, "/v1/sessions/:id/events/socket")
    if (request.method === "GET" && sessionEventId !== undefined) {
      accept((webSocket) => {
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
          /* v8 ignore next */
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

    accept((webSocket) => {
      void attachTerminalSocket(
        services.terminal,
        terminalId,
        {
          lastOutputSeq: numberSearchParam(url, "lastOutputSeq"),
          protocol: numberSearchParam(url, "protocol")
        },
        webSocket
      ).catch(
        /* v8 ignore next */
        () => webSocket.close()
      )
    })
  } catch {
    socket.write("HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n")
    socket.destroy()
  }
}

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

const numberSearchParam = (url: URL, name: string): number => {
  const parsed = Number(url.searchParams.get(name) ?? "0")
  return Number.isFinite(parsed) && parsed > 0 ? parsed : 0
}

const SseFrame = Schema.Struct({ id: Schema.Number, kind: Schema.String })

const writeSse = (response: ServerResponse, data: string): void => {
  const event = decode(SseFrame)(JSON.parse(data))
  response.write(`id: ${event.id}\n`)
  response.write(`event: ${event.kind}\n`)
  response.write(`data: ${data}\n\n`)
}
