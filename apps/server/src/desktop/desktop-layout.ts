import { dirname, join } from "node:path"

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

const ownRuntimeFolder = (system: DesktopSystem): string => join(system.home, ".codevisor", "run")

export const runtimeFolder = (system: DesktopSystem): string => {
  const runtime = system.env["XDG_RUNTIME_DIR"]
  if (runtime !== undefined && runtime !== "" && system.exists(runtime)) return runtime

  return ownRuntimeFolder(system)
}

export const keepOwnFoldersPrivate = (system: DesktopSystem, layout: DesktopLayout): void => {
  const folder = dirname(layout.socket)
  if (folder !== ownRuntimeFolder(system)) return

  system.makePrivateFolder(folder)
  system.closeToOtherAccounts(dirname(folder))
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

export const displayIsOursOrFree = (
  system: DesktopSystem,
  display: number,
  ourSocket: string
): boolean => {
  if (!displayIsTaken(system, display)) return true

  const holder = lockHolder(system, display)
  if (holder === undefined) return false
  if (!system.processAlive(holder)) return true

  return isOurXServer(system, holder, ourSocket)
}

export const ownXServerOn = (
  system: DesktopSystem,
  display: number,
  ourSocket: string
): number | undefined => {
  const holder = lockHolder(system, display)
  if (holder === undefined || !system.processAlive(holder)) return undefined

  return isOurXServer(system, holder, ourSocket) ? holder : undefined
}

export const readyMarkOf = (socket: string): string => `${socket}.ready`

export const x11SocketOf = (display: number): string => `/tmp/.X11-unix/X${display}`

export const x11LockOf = (display: number): string => `/tmp/.X${display}-lock`

export const unitPath = (system: DesktopSystem): string =>
  join(system.home, ".config", "systemd", "user", DESKTOP_UNIT)

const lockHolder = (system: DesktopSystem, display: number): number | undefined => {
  const holder = Number(system.readText(x11LockOf(display))?.trim() ?? "")
  return Number.isInteger(holder) && holder > 0 ? holder : undefined
}

const isOurXServer = (system: DesktopSystem, pid: number, ourSocket: string): boolean =>
  system.readText(`/proc/${pid}/cmdline`)?.includes(ourSocket) === true

const displayIsTaken = (system: DesktopSystem, display: number): boolean =>
  system.exists(x11SocketOf(display)) || system.exists(x11LockOf(display))
