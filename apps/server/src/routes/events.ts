import type { EventEnvelope, TerminalClientFrame } from "@codevisor/api"
import { TerminalClientFrame as TerminalClientFrameSchema, decode } from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"
import type { TerminalManagerService } from "@codevisor/terminal"
import type { IncomingMessage, ServerResponse } from "node:http"
import { adaptDirectSocket } from "./net-direct.js"
import type { Socket } from "node:net"
import { WebSocket, type WebSocketServer } from "ws"
import { CODEVISOR_BROWSER_EXTENSION_ID } from "@codevisor/automation"
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
  for (const event of await run(db.listEvents(Number.isFinite(since) ? since : 0))) {
    writeSse(response, event)
  }
  const unsubscribe = fanout.subscribe((event) => {
    if (isGlobalShellEnvelope(event)) writeSse(response, event)
  })
  response.on("close", unsubscribe)
}

const isGlobalShellEnvelope = (event: EventEnvelope): boolean =>
  event.subjectRevision === undefined || event.globalEventId !== undefined

export const handleUpgrade = async (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  fanout: EventFanout,
  request: IncomingMessage,
  socket: Socket,
  head: Buffer,
  webSocketServer: WebSocketServer
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
    if (request.method === "GET" && url.pathname === "/v1/events/socket") {
      webSocketServer.handleUpgrade(request, socket, head, (webSocket) => {
        void attachEventSocket(
          services.db,
          fanout,
          numberSearchParam(url, "since"),
          webSocket,
          config.id
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
          sessionEventId
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

/// Keepalive cadence for session event sockets. Clients arm a receive
/// deadline (a few multiples of this) once they see the first keepalive, so
/// "no frames" reliably means "dead path" instead of "quiet turn" — the
/// difference between a subway-stalled stream reconnecting in seconds and
/// hanging forever. Session sockets only: old live-only *global* subscribers
/// replace their cursor with the first received id, which a keepalive must
/// never influence.
const EVENT_SOCKET_KEEPALIVE_MS = 25_000

export const attachEventSocket = async (
  db: CodevisorDatabaseService,
  fanout: EventFanout,
  since: number,
  webSocket: WebSocket,
  serverId: string,
  subjectId?: string,
  keepaliveMs: number = EVENT_SOCKET_KEEPALIVE_MS
): Promise<void> => {
  const liveOnly = since >= Number.MAX_SAFE_INTEGER
  let cursor = liveOnly ? 0 : since
  let isReplaying = true
  const liveQueue: Array<EventEnvelope> = []
  const sendEvent = (event: EventEnvelope): void => {
    if (subjectId !== undefined && event.subjectId !== subjectId) {
      return
    }
    // Session-only runtime traffic never enters the global shell log and must
    // not wake every project-list subscriber.
    if (subjectId === undefined && !isGlobalShellEnvelope(event)) {
      return
    }
    const scopedId =
      subjectId === undefined ? (event.globalEventId ?? event.id) : event.subjectRevision
    if (scopedId === undefined || scopedId <= cursor) return
    cursor = scopedId
    if (webSocket.readyState === WebSocket.OPEN) {
      webSocket.send(JSON.stringify(subjectId === undefined ? event : { ...event, id: scopedId }))
    }
  }
  const unsubscribe = fanout.subscribe((event) => {
    if (isReplaying) {
      liveQueue.push(event)
      return
    }
    sendEvent(event)
  })
  webSocket.on("close", unsubscribe)
  if (subjectId !== undefined) {
    const keepalive = setInterval(() => {
      /* v8 ignore next -- the close handler clears the interval before the socket normally leaves OPEN. */
      if (webSocket.readyState !== WebSocket.OPEN) return
      // A full envelope so every client decodes it. `id` is the socket's own
      // cursor: existing clients advance via max(cursor, id), so this can
      // never move a cursor — it only proves the path is alive.
      webSocket.send(
        JSON.stringify({
          id: cursor,
          serverId,
          kind: "keepalive",
          subjectId,
          createdAt: new Date().toISOString(),
          payload: {}
        })
      )
    }, keepaliveMs)
    keepalive.unref()
    webSocket.on("close", () => clearInterval(keepalive))
  }
  try {
    if (!liveOnly) {
      const replay =
        subjectId === undefined
          ? await run(db.listEvents(since))
          : await run(db.listSubjectEvents(subjectId, since))
      for (const event of replay) sendEvent(event)
    }
    isReplaying = false
    for (const event of liveQueue) {
      sendEvent(event)
    }
  } catch {
    /* v8 ignore next -- defensive close path for database failures during websocket replay. */
    unsubscribe()
    /* v8 ignore next -- defensive close path for database failures during websocket replay. */
    webSocket.close()
  }
}

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
