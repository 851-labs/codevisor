import { readFileSync } from "node:fs"
import type { IncomingMessage } from "node:http"
import { connect, type Socket } from "node:net"
import { isAbsolute, join } from "node:path"

import type { ScreenSharingReply, ScreenSharingRequest } from "@codevisor/api"
import { WebSocket } from "ws"

import type { ScreenSharingVNCConfig } from "../server-context-types.js"
import { type PrivateSocket, type PrivateSocketProblem, privateSocket } from "./private-socket.js"
import { type RFBClientMessageKind, RFBClientStreamFilter } from "./rfb-client-filter.js"
import type { VNCDesktopScaler } from "./screen-sharing-vnc-scale.js"
import { type DesktopClipboard, VNCClipboardBridge } from "./vnc-clipboard-bridge.js"
import { systemX11Commands, x11DesktopClipboard } from "./vnc-clipboard-x11.js"
import { type VNCControlArbiter, vncControlArbiter } from "./vnc-control.js"

export const SCREEN_SHARING_CONFIG_FILE = "screen-sharing.json"
export const VNC_SOCKET_PATH = "/v1/screen-sharing/vnc/socket"
export const VNC_DISPLAY_ID = "vnc:desktop"

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
  const vnc = vncSection(text)
  const socket = absolutePath(vnc?.socket)
  if (vnc === undefined || socket === undefined) return undefined

  const display = displayNumber(vnc.display)
  const xauthority = absolutePath(vnc.xauthority)
  return {
    socket,
    name: desktopName(vnc.name),
    ...(vnc.desktop === "xfce" ? { desktop: vnc.desktop } : {}),
    ...(display === undefined ? {} : { display }),
    ...(xauthority === undefined ? {} : { xauthority }),
    ...defaultSize(vnc.defaultSize)
  }
}

export const x11Environment = (
  config: ScreenSharingVNCConfig
): Record<string, string> | undefined => {
  if (config.display === undefined) return undefined

  return {
    DISPLAY: `:${config.display}`,
    ...(config.xauthority === undefined ? {} : { XAUTHORITY: config.xauthority })
  }
}

export const vncDesktopClipboard = (
  config: ScreenSharingVNCConfig
): DesktopClipboard | undefined => {
  const x11 = x11Environment(config)
  if (config.desktop !== "xfce" || x11 === undefined) return undefined

  return x11DesktopClipboard(systemX11Commands(x11))
}

const vncReply = (status: string, message?: string): ScreenSharingReply => ({
  version: 1,
  status,
  provider: "vnc",
  ...(message === undefined ? {} : { message }),
  displays: []
})

const socketProblemMessages: Record<PrivateSocketProblem, string> = {
  missing: "The desktop on this machine isn't running.",
  exposed: "Other accounts on this machine can reach its desktop, so Codevisor won't share it."
}

export const vncScreenSharing =
  (
    config: ScreenSharingVNCConfig,
    scaler?: VNCDesktopScaler,
    locate: (configured: string) => PrivateSocket = privateSocket
  ) =>
  async (request: ScreenSharingRequest): Promise<ScreenSharingReply> => {
    if (request.operation === "capabilities")
      return capabilities(config, scaler, locate(config.socket).problem)
    if (request.operation === "setScale") return setScale(request, scaler)
    return vncReply("unsupported", "This machine streams its display over the VNC socket")
  }

const capabilities = (
  config: ScreenSharingVNCConfig,
  scaler: VNCDesktopScaler | undefined,
  problem: PrivateSocketProblem | undefined
): ScreenSharingReply => {
  if (problem !== undefined) return vncReply("failed", socketProblemMessages[problem])

  return {
    version: 1,
    status: "available",
    provider: "vnc",
    controlLease: true,
    displays: [
      {
        id: VNC_DISPLAY_ID,
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
}

const setScale = async (
  request: ScreenSharingRequest,
  scaler: VNCDesktopScaler | undefined
): Promise<ScreenSharingReply> => {
  if (scaler === undefined) return vncReply("unsupported", "This desktop's scale can't be set")
  if (request.displayId !== VNC_DISPLAY_ID) return vncReply("error", "Unknown display")
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

interface VNCSection {
  readonly socket?: unknown
  readonly name?: unknown
  readonly desktop?: unknown
  readonly display?: unknown
  readonly xauthority?: unknown
  readonly defaultSize?: unknown
}

const vncSection = (text: string): VNCSection | undefined => {
  let parsed: unknown
  try {
    parsed = JSON.parse(text)
  } catch {
    return undefined
  }
  if (typeof parsed !== "object" || parsed === null) return undefined
  const vnc = (parsed as { vnc?: unknown }).vnc
  if (typeof vnc !== "object" || vnc === null) return undefined
  return vnc
}

const absolutePath = (value: unknown): string | undefined =>
  typeof value === "string" && isAbsolute(value) ? value : undefined

const highestDisplayNumber = 65_535

const displayNumber = (value: unknown): number | undefined =>
  typeof value === "number" &&
  Number.isSafeInteger(value) &&
  value >= 0 &&
  value <= highestDisplayNumber
    ? value
    : undefined

const desktopName = (value: unknown): string =>
  typeof value === "string" && value.trim() !== "" ? value.trim() : "Desktop"

const defaultSize = (
  value: unknown
): { defaultWidth: number; defaultHeight: number } | undefined => {
  const size = typeof value === "string" ? /^(\d{2,5})x(\d{2,5})$/.exec(value.trim()) : null
  if (size === null) return undefined
  return { defaultWidth: Number(size[1]), defaultHeight: Number(size[2]) }
}

const refuse = (socket: Socket, status: string): void => {
  socket.write(`HTTP/1.1 ${status}\r\nConnection: close\r\n\r\n`)
  socket.destroy()
}

type VNCWebSocket = Pick<WebSocket, "bufferedAmount" | "readyState" | "close"> & {
  send(data: string | Buffer, options: { binary?: boolean }, callback: () => void): void
  on(event: "message", listener: (bytes: Buffer, isBinary: boolean) => void): unknown
  once(event: "error", listener: () => void): unknown
  once(event: "close", listener: () => void): unknown
}

interface VNCUpgrader {
  handleUpgrade(
    request: IncomingMessage,
    socket: Socket,
    head: Buffer,
    done: (webSocket: VNCWebSocket) => void
  ): void
}

export interface VNCSpliceOptions {
  readonly dial?: (socketPath: string) => Socket
  readonly arbiter?: VNCControlArbiter
  readonly highWater?: number
  readonly desktopClipboard?: DesktopClipboard
  readonly locate?: (configured: string) => PrivateSocket
}

const defaultHighWater = 4 * 1024 * 1024

export const spliceVNCSocket = (
  config: ScreenSharingVNCConfig,
  url: URL,
  request: IncomingMessage,
  socket: Socket,
  head: Buffer,
  webSocketServer: VNCUpgrader,
  options: VNCSpliceOptions = {}
): void => {
  const dial = options.dial ?? ((path: string) => connect({ path }))
  const arbiter = options.arbiter ?? vncControlArbiter(config.socket)
  const highWater = options.highWater ?? defaultHighWater
  const desktopClipboard = options.desktopClipboard ?? vncDesktopClipboard(config)
  const locate = options.locate ?? privateSocket
  if (request.headers.origin !== undefined || request.headers["sec-fetch-site"] !== undefined) {
    refuse(socket, "403 Forbidden")
    return
  }
  if (url.searchParams.get("displayId") !== VNC_DISPLAY_ID) {
    refuse(socket, "404 Not Found")
    return
  }
  webSocketServer.handleUpgrade(request, socket, head, (webSocket) => {
    const located = locate(config.socket)
    if (located.path === undefined) {
      webSocket.close(1011, socketProblemMessages[located.problem])
      return
    }
    const upstream = dial(located.path)
    const sendText = (text: string) => webSocket.send(text, {}, () => undefined)
    const id = arbiter.join(sendText)
    const clipboard =
      desktopClipboard === undefined
        ? undefined
        : new VNCClipboardBridge(desktopClipboard, sendText, () => arbiter.mayControl(id))
    clipboard?.start().catch(() => clipboard.close())
    const filter = new RFBClientStreamFilter()
    const allow = (kind: RFBClientMessageKind) => {
      if (kind === "input" || kind === "clipboard") return arbiter.mayControl(id)
      if (kind === "resize") return arbiter.mayResize(id)
      return true
    }
    webSocket.on("message", (bytes: Buffer, isBinary) => {
      if (!isBinary) {
        const text = bytes.toString("utf8")
        if (clipboard?.receive(text) !== true) arbiter.receive(id, text)
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
      clipboard?.close()
      arbiter.leave(id)
      upstream.destroy()
    })
  })
}
