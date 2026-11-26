import type { ScreenSharingVNCConfig, VNCDesktop, VNCDesktops } from "../server-context-types.js"
import {
  type ScalerCommands,
  systemScalerCommands,
  type VNCDesktopScaler,
  xfceScaler
} from "./screen-sharing-vnc-scale.js"
import { readScreenSharingVNC, vncScreenSharing, x11Environment } from "./screen-sharing-vnc.js"

export const fileVNCDesktops = (
  dataDir: string,
  commands: ScalerCommands = systemScalerCommands
): VNCDesktops => ({
  current: () => {
    const config = readScreenSharingVNC(dataDir)
    if (config === undefined) return undefined

    return desktopFor(config, commands)
  }
})

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
