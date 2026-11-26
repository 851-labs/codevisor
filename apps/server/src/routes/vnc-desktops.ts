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
  outdatedDesktop,
  readDesktopSetup,
  SCREEN_SHARING_CONFIG_FILE,
  vncScreenSharing,
  x11Environment
} from "./screen-sharing-vnc.js"

export const fileVNCDesktops = (
  dataDir: string,
  commands: ScalerCommands = systemScalerCommands,
  log: (line: string) => void = (line) => console.error(line)
): VNCDesktops => {
  const noteSetup = whenItChanges(log)
  const noteSocket = whenItChanges(log)
  const locate = (configured: string): PrivateSocket => {
    const socket = privateSocket(configured)
    noteSocket(socket.problem === undefined ? undefined : `not shared: ${socket.detail}`)
    return socket
  }
  return {
    current: () => {
      const setup = readDesktopSetup(dataDir)
      noteSetup(setupNotices[setup.kind])
      if (setup.kind === "ready") return desktopFor(setup.config, commands, locate)
      if (setup.kind === "outdated") return { respond: outdatedDesktop }

      return undefined
    }
  }
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

const desktopFor = (
  config: ScreenSharingVNCConfig,
  commands: ScalerCommands,
  locate: (configured: string) => PrivateSocket
): VNCDesktop => ({
  config,
  respond: vncScreenSharing(config, scalerFor(config, commands), locate)
})

const scalerFor = (
  config: ScreenSharingVNCConfig,
  commands: ScalerCommands
): VNCDesktopScaler | undefined => {
  const x11 = x11Environment(config)
  if (config.desktop !== "xfce" || x11 === undefined) return undefined

  return xfceScaler(x11, commands)
}
