import type { ScreenSharingVNCConfig, VNCDesktop, VNCDesktops } from "../server-context-types.js"
import { type PrivateSocket, privateSocket } from "./private-socket.js"
import {
  type ScalerCommands,
  systemScalerCommands,
  type VNCDesktopScaler,
  xfceScaler
} from "./screen-sharing-vnc-scale.js"
import {
  type DesktopSetup,
  OUTDATED_DESKTOP,
  outdatedDesktop,
  readDesktopSetup,
  readScreenSetup,
  SCREEN_SHARING_CONFIG_FILE,
  type SharedDisplay,
  VNC_DISPLAY_ID,
  vncScreenSharing,
  whyNotReachable,
  x11Environment
} from "./screen-sharing-vnc.js"
import { type VNCRelay, VNCRelays } from "./vnc-relays.js"

export interface VNCDesktopsOptions {
  readonly commands?: ScalerCommands
  readonly log?: (line: string) => void
  readonly viewerJoined?: (display: ScreenSharingVNCConfig) => void
}

export const fileVNCDesktops = (dataDir: string, options: VNCDesktopsOptions = {}): VNCDesktops => {
  const commands = options.commands ?? systemScalerCommands
  const log = options.log ?? ((line: string) => console.error(line))
  const noteSetup = whenItChanges(log)
  const noteSocket = whenItChanges(log)
  const locate = (configured: string): PrivateSocket => {
    const socket = privateSocket(configured)
    if (configured !== readScreenSetup(dataDir)?.socket)
      noteSocket(socket.problem === undefined ? undefined : `not shared: ${socket.detail}`)
    return socket
  }
  const current = (): VNCDesktop | undefined => {
    const setup = readDesktopSetup(dataDir)
    const screen = readScreenSetup(dataDir)
    noteSetup(setupNotices[setup.kind])
    if (setup.kind === "outdated" && screen === undefined)
      return { displays: [], respond: outdatedDesktop }

    const shared = [
      ...(setup.kind === "ready" ? [virtualDesktop(setup.config, commands)] : []),
      ...(screen === undefined ? [] : [{ config: screen }])
    ]
    if (shared.length === 0) return undefined

    return {
      displays: shared.map((display) => display.config),
      respond: vncScreenSharing(shared, locate, setup.kind === "outdated" ? [outdatedEntry] : [])
    }
  }
  return {
    current,
    relays: new VNCRelays((relay) => whyNotShared(relay, current())),
    ...(options.viewerJoined === undefined ? {} : { viewerJoined: options.viewerJoined })
  }
}

const desktopWithdrawn = "The desktop on this machine was removed."
const outdatedEntry = { id: VNC_DISPLAY_ID, name: "Desktop", problem: OUTDATED_DESKTOP }
const screenWithdrawn = "This machine's screen is no longer shared."

const whyNotShared = (relay: VNCRelay, desktop: VNCDesktop | undefined): string | undefined => {
  const withdrawn = relay.screen === true ? screenWithdrawn : desktopWithdrawn
  const display = desktop?.displays.find((shared) => shared.socket === relay.configured)
  if (display === undefined) return withdrawn

  const socket = privateSocket(relay.configured)
  if (socket.problem !== undefined) return whyNotReachable(display, socket.problem)
  if (socket.path !== relay.dialled) return withdrawn

  return undefined
}

const setupNotices: Record<DesktopSetup["kind"], string | undefined> = {
  ready: undefined,
  absent: undefined,
  outdated: `not shared: ${SCREEN_SHARING_CONFIG_FILE} names a VNC port, which any account on this machine can reach. Set the desktop up again.`,
  unusable: `not shared: the vnc section of ${SCREEN_SHARING_CONFIG_FILE} has no usable socket. It needs "socket" set to an absolute path.`
}

const whenItChanges = (log: (line: string) => void): ((notice: string | undefined) => void) => {
  let last: string | undefined
  return (notice) => {
    if (notice === last) return

    last = notice
    if (notice !== undefined) log(`[desktop] ${notice}`)
  }
}

const virtualDesktop = (
  config: ScreenSharingVNCConfig,
  commands: ScalerCommands
): SharedDisplay => ({
  config,
  scaler: scalerFor(config, commands)
})

const scalerFor = (
  config: ScreenSharingVNCConfig,
  commands: ScalerCommands
): VNCDesktopScaler | undefined => {
  const x11 = x11Environment(config)
  if (config.desktop !== "xfce" || x11 === undefined) return undefined

  return xfceScaler(x11, commands)
}
