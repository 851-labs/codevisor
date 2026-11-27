import { readFileSync } from "node:fs"
import type { IncomingMessage } from "node:http"
import { connect, type Socket } from "node:net"
import { isAbsolute, join } from "node:path"

import type {
  ScreenSharingReply,
  ScreenSharingRequest,
  ScreenSharingUnavailableDisplay
} from "@codevisor/api"
import { WebSocket } from "ws"

import type { ScreenSharingVNCConfig } from "../server-context-types.js"
import { type PrivateSocket, type PrivateSocketProblem, privateSocket } from "./private-socket.js"
import { type RFBClientMessageKind, RFBClientStreamFilter } from "./rfb-client-filter.js"
import { DESKTOP_ENTRY, displayEntry, SCREEN_ENTRY } from "./screen-sharing-config.js"
import type { VNCDesktopScaler } from "./screen-sharing-vnc-scale.js"
import { type DesktopClipboard, VNCClipboardBridge } from "./vnc-clipboard-bridge.js"
import { systemX11Commands, x11DesktopClipboard } from "./vnc-clipboard-x11.js"
import { type VNCControlArbiter, vncControlArbiter } from "./vnc-control.js"
import type { VNCRelays } from "./vnc-relays.js"

export const SCREEN_SHARING_CONFIG_FILE = "screen-sharing.json"
export const VNC_SOCKET_PATH = "/v1/screen-sharing/vnc/socket"
export const VNC_DISPLAY_ID = "vnc:desktop"
export const VNC_SCREEN_ID = "vnc:screen"

export type DesktopSetup =
  | { readonly kind: "ready"; readonly config: ScreenSharingVNCConfig }
  | { readonly kind: "outdated" | "unusable" | "absent" }

export interface SharedDisplay {
  readonly config: ScreenSharingVNCConfig
  readonly scaler?: VNCDesktopScaler | undefined
}

export const displayIdOf = (config: ScreenSharingVNCConfig): string =>
  config.screen === true ? VNC_SCREEN_ID : VNC_DISPLAY_ID

export const readScreenSetup = (dataDir: string): ScreenSharingVNCConfig | undefined => {
  try {
    return screenSetup(readFileSync(join(dataDir, SCREEN_SHARING_CONFIG_FILE), "utf8"))
  } catch {
    return undefined
  }
}

export const screenSetup = (text: string | undefined): ScreenSharingVNCConfig | undefined => {
  const entry = displayEntry(text, SCREEN_ENTRY)
  const vnc = sectionOf(entry?.vnc)
  const socket = absolutePath(vnc?.socket)
  if (socket === undefined || typeof entry?.service !== "string") return undefined

  return { socket, name: nameOr(vnc?.name, "Screen"), screen: true }
}

export const readDesktopSetup = (dataDir: string): DesktopSetup => {
  try {
    return desktopSetup(readFileSync(join(dataDir, SCREEN_SHARING_CONFIG_FILE), "utf8"))
  } catch {
    return { kind: "absent" }
  }
}

export const desktopSetup = (text: string): DesktopSetup => {
  const vnc = vncSection(text)
  if (vnc === undefined) return { kind: "absent" }

  const config = parseScreenSharingVNC(text)
  if (config !== undefined) return { kind: "ready", config }
  if (vnc.socket === undefined && isPort(vnc.port)) return { kind: "outdated" }

  return { kind: "unusable" }
}

export const recordedDesktopService = (text: string): string | undefined => {
  const service = displayEntry(text, DESKTOP_ENTRY)?.service
  return typeof service === "string" ? service : undefined
}

export const OUTDATED_DESKTOP =
  "This machine's desktop was set up for an older version of Codevisor. Set it up again to share it."

export const outdatedDesktop = async (): Promise<ScreenSharingReply> =>
  vncReply("failed", OUTDATED_DESKTOP)

export const parseScreenSharingVNC = (text: string): ScreenSharingVNCConfig | undefined => {
  const vnc = vncSection(text)
  const socket = absolutePath(vnc?.socket)
  if (vnc === undefined || socket === undefined) return undefined

  const display = displayNumber(vnc.display)
  const xauthority = absolutePath(vnc.xauthority)
  return {
    socket,
    name: nameOr(vnc.name, "Desktop"),
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

export const socketProblemMessages: Record<PrivateSocketProblem, string> = {
  missing: "The desktop on this machine isn't running.",
  foreign:
    "The desktop on this machine isn't run by the account Codevisor runs as, so Codevisor won't share it.",
  exposed: "Other accounts on this machine can reach its desktop, so Codevisor won't share it."
}

const screenIsNotShown =
  "This machine's screen isn't being shared right now: nobody is logged in at it, or its session can't be shared."

export const whyNotReachable = (
  config: ScreenSharingVNCConfig,
  problem: PrivateSocketProblem
): string =>
  config.screen === true && problem === "missing"
    ? screenIsNotShown
    : socketProblemMessages[problem]

export const vncScreenSharing =
  (
    shared: ReadonlyArray<SharedDisplay>,
    locate: (configured: string) => PrivateSocket = privateSocket,
    known: ReadonlyArray<ScreenSharingUnavailableDisplay> = []
  ) =>
  async (request: ScreenSharingRequest): Promise<ScreenSharingReply> => {
    if (request.operation === "capabilities") return capabilities(shared, locate, known)
    if (request.operation === "setScale") return setScale(request, shared)
    return vncReply("unsupported", "This machine streams its display over the VNC socket")
  }

interface Looked {
  readonly display: SharedDisplay
  readonly problem: PrivateSocketProblem | undefined
}

const capabilities = (
  shared: ReadonlyArray<SharedDisplay>,
  locate: (configured: string) => PrivateSocket,
  known: ReadonlyArray<ScreenSharingUnavailableDisplay>
): ScreenSharingReply => {
  const looked = shared.map((display) => ({
    display,
    problem: locate(display.config.socket).problem
  }))
  const reachable = looked.filter((one) => one.problem === undefined)
  const unavailable = [...known, ...looked.flatMap(unavailableDisplay)]
  if (reachable.length === 0 && unavailable.length > 0) return noneCanBeViewed(unavailable)

  return {
    version: 1,
    status: "available",
    provider: "vnc",
    controlLease: true,
    displays: reachable.map((one) => listed(one.display)),
    ...(unavailable.length === 0 ? {} : { unavailable })
  }
}

const noneCanBeViewed = (
  unavailable: ReadonlyArray<ScreenSharingUnavailableDisplay>
): ScreenSharingReply => {
  const [only] = unavailable
  if (unavailable.length === 1 && only !== undefined) return vncReply("failed", only.problem)

  const why = unavailable.map((display) => `${display.name}: ${display.problem}`).join("\n")
  return { ...vncReply("failed", why), unavailable }
}

const unavailableDisplay = ({
  display: { config },
  problem
}: Looked): ReadonlyArray<ScreenSharingUnavailableDisplay> =>
  problem === undefined
    ? []
    : [{ id: displayIdOf(config), name: config.name, problem: whyNotReachable(config, problem) }]

const listed = ({ config, scaler }: SharedDisplay) => ({
  id: displayIdOf(config),
  name: config.name,
  width: 0,
  height: 0,
  ...(scaler === undefined ? {} : { scales: [1, 2] }),
  ...(config.defaultWidth === undefined || config.defaultHeight === undefined
    ? {}
    : { defaultWidth: config.defaultWidth, defaultHeight: config.defaultHeight })
})

const setScale = async (
  request: ScreenSharingRequest,
  shared: ReadonlyArray<SharedDisplay>
): Promise<ScreenSharingReply> => {
  const asked = shared.find((display) => displayIdOf(display.config) === request.displayId)
  const scaler = (asked ?? shared[0])?.scaler
  if (scaler === undefined) return vncReply("unsupported", "This desktop's scale can't be set")
  if (asked === undefined) return vncReply("error", "Unknown display")
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
  readonly port?: unknown
  readonly name?: unknown
  readonly desktop?: unknown
  readonly display?: unknown
  readonly xauthority?: unknown
  readonly defaultSize?: unknown
}

const vncSection = (text: string): VNCSection | undefined =>
  sectionOf(displayEntry(text, DESKTOP_ENTRY)?.vnc)

const sectionOf = (vnc: unknown): VNCSection | undefined =>
  typeof vnc === "object" && vnc !== null ? vnc : undefined

const highestPort = 65_535

const isPort = (value: unknown): boolean =>
  typeof value === "number" && Number.isSafeInteger(value) && value >= 1 && value <= highestPort

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

const nameOr = (value: unknown, fallback: string): string =>
  typeof value === "string" && value.trim() !== "" ? value.trim() : fallback

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
  readonly relays?: VNCRelays | undefined
  readonly viewerJoined?: ((display: ScreenSharingVNCConfig) => void) | undefined
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
  if (url.searchParams.get("displayId") !== displayIdOf(config)) {
    refuse(socket, "404 Not Found")
    return
  }
  webSocketServer.handleUpgrade(request, socket, head, (webSocket) => {
    const located = locate(config.socket)
    if (located.path === undefined) {
      webSocket.close(1011, whyNotReachable(config, located.problem))
      return
    }
    const upstream = dial(located.path)
    upstream.once("connect", () => options.viewerJoined?.(config))
    const sendText = (text: string) => webSocket.send(text, {}, () => undefined)
    const id = arbiter.join(sendText)
    const clipboard =
      desktopClipboard === undefined
        ? undefined
        : new VNCClipboardBridge(desktopClipboard, sendText, () => arbiter.mayControl(id))
    clipboard?.start().catch(() => clipboard.close())
    let cutOff = false
    const release = () => {
      clipboard?.close()
      arbiter.leave(id)
      upstream.destroy()
    }
    const leaveRelays = options.relays?.add({
      screen: config.screen === true,
      configured: config.socket,
      dialled: located.path,
      close: (reason) => {
        cutOff = true
        release()
        webSocket.close(1011, reason)
      }
    })
    const filter = new RFBClientStreamFilter()
    const allow = (kind: RFBClientMessageKind) => {
      if (kind === "input" || kind === "clipboard") return arbiter.mayControl(id)
      if (kind === "resize") return config.screen !== true && arbiter.mayResize(id)
      return true
    }
    webSocket.on("message", (bytes: Buffer, isBinary) => {
      if (cutOff) return
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
      leaveRelays?.()
      release()
    })
  })
}
