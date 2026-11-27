import { type PrivateSocket, privateSocket } from "../routes/private-socket.js"
import { readyMarkOf } from "./desktop-layout.js"
import type { DesktopSystem } from "./desktop-system.js"

export type LocateSocket = (configured: string) => PrivateSocket

export type DesktopProcesses = Pick<DesktopSystem, "readText" | "processAlive">

export interface OwnDesktop {
  readonly dataDir: string
  readonly socket: string
}

export const desktopIsUp = (
  system: DesktopProcesses,
  desktop: OwnDesktop,
  locate: LocateSocket = privateSocket
): boolean => whyDesktopIsDown(system, desktop, locate) === undefined

export const whyDesktopIsDown = (
  system: DesktopProcesses,
  desktop: OwnDesktop,
  locate: LocateSocket = privateSocket
): string | undefined => {
  const found = locate(desktop.socket)
  if (found.problem !== undefined) return found.detail

  return ownRunnerIsAlive(system, desktop) ? undefined : "the desktop's session isn't up"
}

const ownRunnerIsAlive = (system: DesktopProcesses, desktop: OwnDesktop): boolean => {
  const runner = Number(system.readText(readyMarkOf(desktop.socket))?.trim() ?? "")
  if (!Number.isInteger(runner) || runner <= 0 || !system.processAlive(runner)) return false

  const commandLine = system.readText(`/proc/${runner}/cmdline`)
  return commandLine?.includes(runnerOf(desktop.dataDir)) === true
}

const runnerOf = (dataDir: string): string => `\0desktop\0run\0--data-dir\0${dataDir}\0`
