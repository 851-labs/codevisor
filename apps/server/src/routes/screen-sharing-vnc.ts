import { readFileSync } from "node:fs"
import type { IncomingMessage } from "node:http"
import { connect, type Socket } from "node:net"
import { join } from "node:path"

import type { ScreenSharingReply, ScreenSharingRequest } from "@codevisor/api"
import { createWebSocketStream, type WebSocketServer } from "ws"

import type { ScreenSharingVNCConfig } from "../server-context-types.js"
import type { VNCDesktopScaler } from "./screen-sharing-vnc-scale.js"

/// `~/.codevisor/data/screen-sharing.json`, written by whoever set the
/// machine up (scripts/vnc-desktop.sh), never by a client:
///
///     { "vnc": { "port": 5901, "name": "Desktop" } }
///
/// A VNC server on this machine's loopback then becomes the workspace's
/// display. The app never learns the port or a password; it only sees a
/// display id and the socket route below.
export const SCREEN_SHARING_CONFIG_FILE = "screen-sharing.json"
export const VNC_SOCKET_PATH = "/v1/screen-sharing/vnc/socket"

export const readScreenSharingVNC = (dataDir: string): ScreenSharingVNCConfig | undefined => {
  let text: string
  try {
    text = readFileSync(join(dataDir, SCREEN_SHARING_CONFIG_FILE), "utf8")
  } catch {
    return undefined
  }
  return parseScreenSharingVNC(text)
}

export const parseScreenSharingVNC = (text: string): ScreenSharingVNCConfig | undefined => {
  let parsed: unknown
  try {
    parsed = JSON.parse(text)
  } catch {
    return undefined
  }
  if (typeof parsed !== "object" || parsed === null) return undefined
  const vnc = (parsed as { vnc?: unknown }).vnc
  if (typeof vnc !== "object" || vnc === null) return undefined
  const { port, name, desktop, defaultSize } = vnc as {
    port?: unknown
    name?: unknown
    desktop?: unknown
    defaultSize?: unknown
  }
  if (typeof port !== "number" || !Number.isSafeInteger(port) || port < 1 || port > 65_535)
    return undefined
  const size =
    typeof defaultSize === "string" ? /^(\d{2,5})x(\d{2,5})$/.exec(defaultSize.trim()) : null
  return {
    port,
    name: typeof name === "string" && name.trim() !== "" ? name.trim() : "Desktop",
    ...(desktop === "xfce" ? { desktop } : {}),
    ...(size ? { defaultWidth: Number(size[1]), defaultHeight: Number(size[2]) } : {})
  }
}

export const vncDisplayId = (config: ScreenSharingVNCConfig): string => `vnc:${config.port}`

/// The signaling helper for a VNC-backed machine. `capabilities` describes the
/// desktop; video does not go over WebRTC here but over the socket route, and
/// the viewer measures the desktop itself during the RFB handshake. With a
/// `scaler` (an Xfce desktop, 851-2339) `setScale` sets the desktop's UI scale.
export const vncScreenSharing =
  (config: ScreenSharingVNCConfig, scaler?: VNCDesktopScaler) =>
  async (request: ScreenSharingRequest): Promise<ScreenSharingReply> => {
    const reply = (status: string, message?: string): ScreenSharingReply => ({
      version: 1,
      status,
      provider: "vnc",
      ...(message === undefined ? {} : { message }),
      displays: []
    })
    if (request.operation === "capabilities")
      return {
        version: 1,
        status: "available",
        provider: "vnc",
        displays: [
          {
            id: vncDisplayId(config),
            name: config.name,
            width: 0,
            height: 0,
            ...(scaler === undefined ? {} : { scales: [1, 2] }),
            ...(config.defaultWidth === undefined || config.defaultHeight === undefined
              ? {}
              : { defaultWidth: config.defaultWidth, defaultHeight: config.defaultHeight })
          }
        ]
      }
    if (request.operation === "setScale") {
      if (scaler === undefined) return reply("unsupported", "This desktop's scale can't be set")
      if (request.displayId !== vncDisplayId(config)) return reply("error", "Unknown display")
      if (request.scale === undefined) return reply("error", "No scale")
      try {
        await scaler(request.scale)
      } catch (error) {
        return reply(
          "error",
          error instanceof Error ? error.message : "The desktop's scale couldn't be set"
        )
      }
      return reply("ok")
    }
    return reply("unsupported", "This machine streams its display over the VNC socket")
  }

const refuse = (socket: Socket, status: string): void => {
  socket.write(`HTTP/1.1 ${status}\r\nConnection: close\r\n\r\n`)
  socket.destroy()
}

/// Splices one machine-authenticated WebSocket onto the loopback VNC server:
/// binary frames become RFB bytes and back. The display id must match so a
/// pane opened against an earlier configuration cannot reach whatever now
/// listens on that port.
export const spliceVNCSocket = (
  config: ScreenSharingVNCConfig,
  url: URL,
  request: IncomingMessage,
  socket: Socket,
  head: Buffer,
  webSocketServer: WebSocketServer,
  dial: (port: number) => Socket = (port) => connect({ host: "127.0.0.1", port })
): void => {
  // Websites cannot use loopback trust, as with the signaling route.
  if (request.headers.origin !== undefined || request.headers["sec-fetch-site"] !== undefined) {
    refuse(socket, "403 Forbidden")
    return
  }
  if (url.searchParams.get("displayId") !== vncDisplayId(config)) {
    refuse(socket, "404 Not Found")
    return
  }
  webSocketServer.handleUpgrade(request, socket, head, (webSocket) => {
    const upstream = dial(config.port)
    const stream = createWebSocketStream(webSocket)
    // Closing the WebSocket first keeps the reason; the stream's own close
    // then tears down the (already failed) loopback socket.
    upstream.once("error", () => webSocket.close(1011, "VNC server unavailable"))
    upstream.once("close", () => stream.end())
    stream.once("error", () => upstream.destroy())
    stream.once("close", () => upstream.destroy())
    stream.pipe(upstream)
    upstream.pipe(stream)
  })
}
