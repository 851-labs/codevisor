import { type PrivateSocket, privateSocket } from "../routes/private-socket.js"
import { readyMarkOf } from "./desktop-layout.js"
import type { DesktopSystem } from "./desktop-system.js"

export type LocateSocket = (configured: string) => PrivateSocket

export type DesktopProcesses = Pick<DesktopSystem, "readText" | "processAlive">

export const desktopIsUp = (
  system: DesktopProcesses,
  socket: string,
  locate: LocateSocket = privateSocket
): boolean => whyDesktopIsDown(system, socket, locate) === undefined

export const whyDesktopIsDown = (
  system: DesktopProcesses,
  socket: string,
  locate: LocateSocket = privateSocket
): string | undefined => {
  const found = locate(socket)
  if (found.problem !== undefined) return found.detail

  return sessionRunnerIsAlive(system, socket) ? undefined : "the desktop's session isn't up"
}

const sessionRunnerIsAlive = (system: DesktopProcesses, socket: string): boolean => {
  const runner = Number(system.readText(readyMarkOf(socket))?.trim() ?? "")
  if (!Number.isInteger(runner) || runner <= 0 || !system.processAlive(runner)) return false

  return system.readText(`/proc/${runner}/cmdline`)?.includes(runnerArguments) === true
}

const runnerArguments = "\0desktop\0run\0"
