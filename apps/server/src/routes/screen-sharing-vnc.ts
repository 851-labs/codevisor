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

export const vncScreenSharing =
  (config: ScreenSharingVNCConfig, scaler?: VNCDesktopScaler) =>
  async (request: ScreenSharingRequest): Promise<ScreenSharingReply> => {
    if (request.operation === "capabilities")
      return {
        version: 1,
        status: "available",
        provider: "vnc",
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

export const spliceVNCSocket = (
  config: ScreenSharingVNCConfig,
  url: URL,
  request: IncomingMessage,
  socket: Socket,
  head: Buffer,
  webSocketServer: WebSocketServer,
  dial: (port: number) => Socket = (port) => connect({ host: "127.0.0.1", port }),
  arbiter: VNCControlArbiter = vncControlArbiter(config.port),
  highWater = 4 * 1024 * 1024
): void => {
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
    upstream.on("data", (chunk: Buffer) => {
      webSocket.send(chunk, { binary: true }, () => {
        if (upstream.isPaused() && webSocket.bufferedAmount < highWater) upstream.resume()
      })
      if (webSocket.bufferedAmount >= highWater) upstream.pause()
    })
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
