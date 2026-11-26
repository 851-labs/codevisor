import type { ScreenSharingVNCConfig, VNCDesktop, VNCDesktops } from "../server-context-types.js"
import {
  type ScalerCommands,
  systemScalerCommands,
  type VNCDesktopScaler,
  xfceScaler
} from "./screen-sharing-vnc-scale.js"
import {
  namesOnlyAPort,
  outdatedDesktop,
  parseScreenSharingVNC,
  readDesktopConfig,
  SCREEN_SHARING_CONFIG_FILE,
  vncScreenSharing,
  x11Environment
} from "./screen-sharing-vnc.js"

export const fileVNCDesktops = (
  dataDir: string,
  commands: ScalerCommands = systemScalerCommands,
  log: (line: string) => void = (line) => console.error(line)
): VNCDesktops => {
  let outdatedNoted = false
  return {
    current: () => {
      const text = readDesktopConfig(dataDir)
      if (text === undefined || !namesOnlyAPort(text)) outdatedNoted = false
      if (text === undefined) return undefined

      const config = parseScreenSharingVNC(text)
      if (config !== undefined) return desktopFor(config, commands)
      if (!namesOnlyAPort(text)) return undefined

      if (!outdatedNoted) log(outdatedNotice)
      outdatedNoted = true
      return { respond: outdatedDesktop }
    }
  }
}

const outdatedNotice = `[desktop] ${SCREEN_SHARING_CONFIG_FILE} names a VNC port, which any account on this machine can reach, so the desktop is not shared. Set the desktop up again.`

const desktopFor = (config: ScreenSharingVNCConfig, commands: ScalerCommands): VNCDesktop => ({
  config,
  respond: vncScreenSharing(config, scalerFor(config, commands))
})

const scalerFor = (
  config: ScreenSharingVNCConfig,
  commands: ScalerCommands
): VNCDesktopScaler | undefined => {
  const x11 = x11Environment(config)
  if (config.desktop !== "xfce" || x11 === undefined) return undefined

  return xfceScaler(x11, commands)
}
