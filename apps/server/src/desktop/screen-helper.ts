import { basename } from "node:path"

import { keepOwnFoldersPrivate } from "./desktop-layout.js"
import type { LocateSocket } from "./desktop-liveness.js"
import type { DesktopSystem } from "./desktop-system.js"
import { holdsUnixSocket, tcpPortsListenedOnBy } from "./listening-ports.js"
import {
  controlSocketOf,
  helperCommand,
  helperName,
  type Scraper,
  type ShownScreen
} from "./screen-commands.js"

export interface RunningHelper {
  readonly pid: number
  readonly shows: string | undefined
  readonly socket: string
}

export type { ShownScreen } from "./screen-commands.js"

export type TcpPortsOf = (helper: number, socket: string) => ReadonlyArray<number> | undefined

export interface ScreenHelperOptions {
  readonly system: DesktopSystem
  readonly pidFile: string
  readonly logFile: string
  readonly locate: LocateSocket
  readonly tcpPortsOf?: TcpPortsOf | undefined
}

export interface ScreenHelpers {
  readonly running: () => RunningHelper | undefined
  readonly start: (
    socket: string,
    shown: ShownScreen,
    scraper: Scraper
  ) => Promise<string | undefined>
  readonly stop: (helper: RunningHelper) => Promise<boolean>
  readonly forget: (socket: string) => boolean
  readonly started: () => boolean
}

const pollMs = 100
const socketPolls = 50
const stopPolls = 50
const portSettleMs = 1000
const socketPrefix = "codevisor-screen-"

export const screenSocketPrefix = socketPrefix

export const stillRunning = (pid: number): string =>
  `the screen's VNC server (process ${pid}) doesn't stop, even when killed`

export const screenHelpers = (options: ScreenHelperOptions): ScreenHelpers => {
  const { system, pidFile, logFile, locate } = options
  const tcpPortsOf = options.tcpPortsOf ?? tcpPortsOfTheHelper

  const running = (): RunningHelper | undefined => {
    const pid = Number(system.readText(pidFile)?.trim() ?? "")
    if (!Number.isInteger(pid) || pid <= 0 || !system.processAlive(pid)) return undefined

    const words = (system.readText(`/proc/${pid}/cmdline`) ?? "").split("\0")
    const socket = words.find(isOurSocket)
    if (socket === undefined) return undefined

    return { pid, shows: valueOf(words, "-display") ?? waylandOf(pid), socket }
  }

  const waylandOf = (pid: number): string | undefined => {
    const environ = (system.readText(`/proc/${pid}/environ`) ?? "").split("\0")
    return environ
      .find((pair) => pair.startsWith("WAYLAND_DISPLAY="))
      ?.slice("WAYLAND_DISPLAY=".length)
  }

  const forget = (socket: string): boolean => {
    const wasThere = system.exists(socket) || system.exists(pidFile)
    system.remove(pidFile)
    system.remove(socket)
    system.remove(controlSocketOf(socket))
    return wasThere
  }

  const exits = async (pid: number): Promise<boolean> => {
    for (let poll = 0; poll < stopPolls && system.processAlive(pid); poll += 1)
      await system.sleep(pollMs)
    return !system.processAlive(pid)
  }

  const stop = async (helper: RunningHelper): Promise<boolean> => {
    system.terminate(helper.pid)
    if (!(await exits(helper.pid))) system.terminate(helper.pid, "SIGKILL")
    if (!(await exits(helper.pid))) return false

    forget(helper.socket)
    return true
  }

  const started = (): boolean => system.exists(pidFile)

  const socketOpens = async (socket: string): Promise<boolean> => {
    for (let poll = 0; poll < socketPolls; poll += 1) {
      if (locate(socket).problem === undefined) return true

      await system.sleep(pollMs)
    }
    return false
  }

  const portsNow = (pid: number, socket: string): ReadonlyArray<number> | undefined => {
    try {
      return tcpPortsOf(pid, socket)
    } catch {
      return undefined
    }
  }

  const whyItMayNotBeShared = async (
    pid: number,
    socket: string,
    name: string
  ): Promise<string | undefined> => {
    if (!(await socketOpens(socket))) return `${name} didn't open its socket (see ${logFile})`

    const first = portsNow(pid, socket)
    await system.sleep(portSettleMs)
    const second = portsNow(pid, socket)
    if (first === undefined || second === undefined)
      return `couldn't check that ${name} stays off the network`

    const port = [...first, ...second][0]
    return port === undefined
      ? undefined
      : `${name} listens on TCP port ${port}, and the screen must only be shared on its socket`
  }

  const start = async (
    socket: string,
    shown: ShownScreen,
    scraper: Scraper
  ): Promise<string | undefined> => {
    keepOwnFoldersPrivate(system, { socket })
    forget(socket)
    const name = helperName(scraper.program)
    const { program, args } = helperCommand(scraper, shown, socket)
    const pid = system.spawnDetached(program, args, logFile)
    if (pid === undefined) return `${name} couldn't be started`

    system.writeText(pidFile, `${pid}\n`)
    const why = await whyItMayNotBeShared(pid, socket, name)
    if (why === undefined) return undefined
    if (!(await stop({ pid, shows: shown.shows, socket }))) return `${why}; ${stillRunning(pid)}`

    return why
  }

  return { running, start, stop, forget, started }
}

const tcpPortsOfTheHelper: TcpPortsOf = (helper, socket) =>
  holdsUnixSocket(helper, socket) ? tcpPortsListenedOnBy(helper) : undefined

const valueOf = (words: ReadonlyArray<string>, flag: string): string | undefined => {
  const at = words.indexOf(flag)
  return at < 0 ? undefined : words[at + 1]
}

const isOurSocket = (word: string): boolean =>
  basename(word).startsWith(socketPrefix) && word.endsWith(".sock")
