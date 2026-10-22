import type { IncomingMessage } from "node:http"
import type { Socket } from "node:net"

import { CODEVISOR_BROWSER_EXTENSION_ID } from "@codevisor/automation"
import type { CodevisorDatabaseService } from "@codevisor/db"
import type { WebSocket, WebSocketServer } from "ws"

import type { ClientControlBroker } from "../infra/client-control.js"
import {
  isLocalhost,
  matchRoute,
  type CodevisorServerConfig,
  type CodevisorServerServices,
  type EventFanout
} from "../server-context.js"
import { attachLivePreviewSocket, LIVE_PREVIEW_SOCKET_PATH } from "./live-preview-socket.js"
import { adaptDirectSocket } from "./net-direct.js"
import { spliceVNCSocket, VNC_SOCKET_PATH } from "./screen-sharing-vnc.js"
import { attachSyncEventSocket } from "./sync-event-socket.js"
import { attachTerminalSocket } from "./terminal-socket.js"

export interface SocketUpgrade {
  readonly services: CodevisorServerServices
  readonly config: CodevisorServerConfig
  readonly fanout: EventFanout
  readonly request: IncomingMessage
  readonly socket: Socket
  readonly head: Buffer
  readonly webSocketServer: WebSocketServer
  readonly clientControl: ClientControlBroker | undefined
}

const EVENT_SOCKET_KEEPALIVE_MS = 25_000

const BROWSER_EXTENSION_ORIGIN = `chrome-extension://${CODEVISOR_BROWSER_EXTENSION_ID}`

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

export const acceptPublicSocket = (upgrade: SocketUpgrade, url: URL): boolean => {
  if (acceptBrowserExtension(upgrade, url)) return true
  if (acceptBrowserNativeHost(upgrade, url)) return true
  return acceptDirectConnection(upgrade, url)
}

export const acceptAuthorizedSocket = (upgrade: SocketUpgrade, url: URL): void => {
  if (acceptLivePreview(upgrade, url)) return
  if (spliceScreenSharing(upgrade, url)) return
  if (acceptBrowserHost(upgrade, url)) return
  if (acceptClientControl(upgrade, url)) return
  if (acceptEventStream(upgrade, url)) return
  if (acceptSessionEventStream(upgrade, url)) return
  acceptTerminal(upgrade, url)
}

const acceptBrowserExtension = (upgrade: SocketUpgrade, url: URL): boolean => {
  if (!isBrowserExtensionSocket(upgrade, url)) return false

  accept(upgrade, (webSocket) => {
    upgrade.services.mcp!.acceptBrowserExtension(webSocket)
  })
  return true
}

const acceptBrowserNativeHost = (upgrade: SocketUpgrade, url: URL): boolean => {
  if (!isBrowserNativeHostSocket(upgrade, url)) return false

  accept(upgrade, (webSocket) => {
    upgrade.services.mcp!.acceptBrowserNativeHost(webSocket)
  })
  return true
}

const acceptDirectConnection = (upgrade: SocketUpgrade, url: URL): boolean => {
  const { request, config } = upgrade
  if (!isGetTo(request, url, "/v1/direct")) return false
  if (!config.directPathEnabled) return false
  if (config.cloud?.acceptDirect === undefined) return false

  const acceptDirect = config.cloud.acceptDirect
  accept(upgrade, (webSocket) => {
    if (!acceptDirect(adaptDirectSocket(webSocket))) {
      webSocket.close(1013, "no cloud identity to serve direct connections")
    }
  })
  return true
}

const acceptLivePreview = (upgrade: SocketUpgrade, url: URL): boolean => {
  const { services, request } = upgrade
  const previewSession = url.searchParams.get("sessionId")
  if (!isGetTo(request, url, LIVE_PREVIEW_SOCKET_PATH)) return false
  if (previewSession === null) return false
  if (services.mcp === undefined) return false

  const mcp = services.mcp
  accept(upgrade, (webSocket) => attachLivePreviewSocket(mcp, previewSession, webSocket))
  return true
}

const spliceScreenSharing = (upgrade: SocketUpgrade, url: URL): boolean => {
  const { config, request, socket, head, webSocketServer } = upgrade
  if (!isGetTo(request, url, VNC_SOCKET_PATH)) return false
  if (config.screenSharingVNC === undefined) return false

  spliceVNCSocket(config.screenSharingVNC, url, request, socket, head, webSocketServer)
  return true
}

const acceptBrowserHost = (upgrade: SocketUpgrade, url: URL): boolean => {
  const { services, request } = upgrade
  if (!isGetTo(request, url, "/v1/browser-use/host/socket")) return false
  if (services.mcp === undefined) return false

  const mcp = services.mcp
  accept(upgrade, (webSocket) => mcp.acceptBrowserHost(webSocket))
  return true
}

const acceptClientControl = (upgrade: SocketUpgrade, url: URL): boolean => {
  const { request, clientControl } = upgrade
  const clientId = matchRoute(url.pathname, "/v1/clients/:id/socket")
  if (request.method !== "GET") return false
  if (clientId === undefined) return false
  if (clientControl === undefined) return false

  accept(upgrade, (webSocket) => {
    clientControl.attach(clientId, webSocket)
  })
  return true
}

const acceptEventStream = (upgrade: SocketUpgrade, url: URL): boolean => {
  if (!isGetTo(upgrade.request, url, "/v1/events/socket")) return false

  accept(upgrade, (webSocket) => streamEvents(upgrade, url, webSocket, undefined))
  return true
}

const acceptSessionEventStream = (upgrade: SocketUpgrade, url: URL): boolean => {
  const sessionId = matchRoute(url.pathname, "/v1/sessions/:id/events/socket")
  if (upgrade.request.method !== "GET") return false
  if (sessionId === undefined) return false

  accept(upgrade, (webSocket) => streamEvents(upgrade, url, webSocket, sessionId))
  return true
}

const acceptTerminal = (upgrade: SocketUpgrade, url: URL): void => {
  const terminalId = matchRoute(url.pathname, "/v1/terminals/:id/socket")
  if (terminalId === undefined) {
    upgrade.socket.destroy()
    return
  }

  accept(upgrade, (webSocket) => attachTerminal(upgrade, url, terminalId, webSocket))
}

const accept = (
  { request, socket, head, webSocketServer }: SocketUpgrade,
  onSocket: (webSocket: WebSocket) => void
): void => {
  webSocketServer.handleUpgrade(request, socket, head, (webSocket) => {
    webSocket.on("error", () => undefined)
    onSocket(webSocket)
  })
}

const streamEvents = (
  { services, fanout, config }: SocketUpgrade,
  url: URL,
  webSocket: WebSocket,
  subjectId: string | undefined
): void => {
  void attachEventSocket(
    services.db,
    fanout,
    numberSearchParam(url, "since"),
    webSocket,
    config.id,
    subjectId,
    EVENT_SOCKET_KEEPALIVE_MS,
    url.searchParams.get("sync") === "1"
  ).catch(
    /* v8 ignore next */
    () => webSocket.close()
  )
}

const attachTerminal = (
  { services }: SocketUpgrade,
  url: URL,
  terminalId: string,
  webSocket: WebSocket
): void => {
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
}

const isBrowserExtensionSocket = ({ services, request }: SocketUpgrade, url: URL): boolean =>
  isGetTo(request, url, "/v1/browser-use/extension/socket") &&
  services.mcp !== undefined &&
  isLocalhost(request.socket.remoteAddress) &&
  request.headers.origin === BROWSER_EXTENSION_ORIGIN

const isBrowserNativeHostSocket = ({ services, request }: SocketUpgrade, url: URL): boolean =>
  isGetTo(request, url, "/v1/browser-use/extension/native") &&
  services.mcp !== undefined &&
  isLocalhost(request.socket.remoteAddress) &&
  request.headers.origin === undefined

const isGetTo = (request: IncomingMessage, url: URL, pathname: string): boolean =>
  request.method === "GET" && url.pathname === pathname

const numberSearchParam = (url: URL, name: string): number => {
  const parsed = Number(url.searchParams.get(name) ?? "0")
  return Number.isFinite(parsed) && parsed > 0 ? parsed : 0
}
