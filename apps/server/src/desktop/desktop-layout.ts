import { join } from "node:path"

import type { DesktopSystem } from "./desktop-system.js"

export interface DesktopLayout {
  readonly socket: string
  readonly xauthority: string
  readonly display: number
}

export const DESKTOP_UNIT = "codevisor-desktop.service"
export const DESKTOP_SIZE = "1440x900"

const firstDisplay = 1
const lastDisplay = 99

export const runtimeFolder = (system: DesktopSystem): string => {
  const runtime = system.env["XDG_RUNTIME_DIR"]
  if (runtime !== undefined && runtime !== "" && system.exists(runtime)) return runtime

  return join(system.home, ".codevisor", "run")
}

export const desktopLayout = (system: DesktopSystem, display: number): DesktopLayout => {
  const folder = runtimeFolder(system)
  return {
    socket: join(folder, "codevisor-desktop.sock"),
    xauthority: join(folder, "codevisor-desktop.xauth"),
    display
  }
}

export const freeDisplay = (system: DesktopSystem): number | undefined => {
  for (let display = firstDisplay; display <= lastDisplay; display += 1) {
    if (!displayIsTaken(system, display)) return display
  }
  return undefined
}

export const x11SocketOf = (display: number): string => `/tmp/.X11-unix/X${display}`

export const x11LockOf = (display: number): string => `/tmp/.X${display}-lock`

export const unitPath = (system: DesktopSystem): string =>
  join(system.home, ".config", "systemd", "user", DESKTOP_UNIT)

const displayIsTaken = (system: DesktopSystem, display: number): boolean =>
  system.exists(x11SocketOf(display)) || system.exists(x11LockOf(display))
