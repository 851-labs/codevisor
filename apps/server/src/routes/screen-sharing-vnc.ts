import { readFileSync } from "node:fs"
import type { IncomingMessage } from "node:http"
import { connect, type Socket } from "node:net"
import { join } from "node:path"

import type { ScreenSharingReply, ScreenSharingRequest } from "@codevisor/api"
import { WebSocket, type WebSocketServer } from "ws"

import type { ScreenSharingVNCConfig } from "../server-context-types.js"
import { type RFBClientMessageKind, RFBClientStreamFilter } from "./rfb-client-filter.js"
import type { VNCDesktopScaler } from "./screen-sharing-vnc-scale.js"
import { type VNCControlArbiter, vncControlArbiter } from "./vnc-control.js"

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

const vncReply = (status: string, message?: string): ScreenSharingReply => ({
  version: 1,
  status,
  provider: "vnc",
  ...(message === undefined ? {} : { message }),
  displays: []
})

/// The signaling helper for a VNC-backed machine. `capabilities` describes the
/// desktop; video does not go over WebRTC here but over the socket route, and
/// the viewer measures the desktop itself during the RFB handshake. With a
/// `scaler` (an Xfce desktop, 851-2339) `setScale` sets the desktop's UI scale.
export const vncScreenSharing =
  (config: ScreenSharingVNCConfig, scaler?: VNCDesktopScaler) =>
  async (request: ScreenSharingRequest): Promise<ScreenSharingReply> => {
    if (request.operation === "capabilities")
      return {
        version: 1,
        status: "available",
        provider: "vnc",
        // Viewers may take control through the socket's lease messages (851-2338).
        controlLease: true,
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
      if (scaler === undefined) return vncReply("unsupported", "This desktop's scale can't be set")
      if (request.displayId !== vncDisplayId(config)) return vncReply("error", "Unknown display")
      if (request.scale === undefined) return vncReply("error", "No scale")
      try {
        await scaler(request.scale)
      } catch (error) {
        return vncReply(
          "error",
          error instanceof Error ? error.message : "The desktop's scale couldn't be set"
        )
      }
      return vncReply("ok")
    }
    return vncReply("unsupported", "This machine streams its display over the VNC socket")
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
  dial: (port: number) => Socket = (port) => connect({ host: "127.0.0.1", port }),
  arbiter: VNCControlArbiter = vncControlArbiter(config.port),
  /// Bytes queued on the WebSocket before the loopback read pauses.
  highWater = 4 * 1024 * 1024
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
    // One controller at a time (851-2338): text frames are the lease's messages, binary
    // frames the viewer's RFB bytes, filtered so only who may control reaches the desktop.
    // A lease message to a socket that is closing is dropped (the callback takes the error).
    const id = arbiter.join((text) => webSocket.send(text, () => undefined))
    const filter = new RFBClientStreamFilter()
    const allow = (kind: RFBClientMessageKind) =>
      kind === "input" || kind === "clipboard"
        ? arbiter.mayControl(id)
        : kind === "resize"
          ? arbiter.mayResize(id)
          : true
    webSocket.on("message", (bytes: Buffer, isBinary) => {
      if (!isBinary) {
        arbiter.receive(id, bytes.toString("utf8"))
        return
      }
      const forward = filter.push(bytes, allow)
      if (forward.length > 0) upstream.write(forward)
    })
    // The desktop's bytes go out as they come; a slow WebSocket pauses the loopback read.
    upstream.on("data", (chunk: Buffer) => {
      webSocket.send(chunk, { binary: true }, () => {
        if (upstream.isPaused() && webSocket.bufferedAmount < highWater) upstream.resume()
      })
      if (webSocket.bufferedAmount >= highWater) upstream.pause()
    })
    // Closing the WebSocket first keeps the reason; its close then tears down the loopback socket.
    upstream.once("error", () => webSocket.close(1011, "VNC server unavailable"))
    upstream.once("close", () => {
      if (webSocket.readyState === WebSocket.OPEN) webSocket.close()
    })
    webSocket.once("error", () => upstream.destroy())
    webSocket.once("close", () => {
      arbiter.leave(id)
      upstream.destroy()
    })
  })
}
