import { keepOwnFoldersPrivate } from "./desktop-layout.js"
import type { LocateSocket } from "./desktop-liveness.js"
import type { DesktopSystem } from "./desktop-system.js"
import { holdsUnixSocket, tcpPortsListenedOnBy } from "./listening-ports.js"

export interface RunningHelper {
  readonly pid: number
  readonly display: string | undefined
}

export interface ShownScreen {
  readonly display: string
  readonly env: Readonly<Record<string, string>>
}

export type TcpPortsOf = (helper: number, socket: string) => ReadonlyArray<number> | undefined

export interface ScreenHelperOptions {
  readonly system: DesktopSystem
  readonly pidFile: string
  readonly logFile: string
  readonly locate: LocateSocket
  readonly tcpPortsOf?: TcpPortsOf | undefined
}

export interface ScreenHelpers {
  readonly running: (socket: string) => RunningHelper | undefined
  readonly start: (
    socket: string,
    shown: ShownScreen,
    scraper: string
  ) => Promise<string | undefined>
  readonly stop: (helper: RunningHelper, socket: string) => Promise<boolean>
  readonly forget: (socket: string) => boolean
  readonly started: () => boolean
}

const pollMs = 100
const socketPolls = 50
const stopPolls = 50
const portSettleMs = 1000
const unchecked = "couldn't check that x0vncserver stays off the network"

export const stillRunning = (pid: number): string =>
  `x0vncserver (process ${pid}) doesn't stop, even when killed`

export const screenHelpers = (options: ScreenHelperOptions): ScreenHelpers => {
  const { system, pidFile, logFile, locate } = options
  const tcpPortsOf = options.tcpPortsOf ?? tcpPortsOfTheHelper

  const running = (socket: string): RunningHelper | undefined => {
    const pid = Number(system.readText(pidFile)?.trim() ?? "")
    if (!Number.isInteger(pid) || pid <= 0 || !system.processAlive(pid)) return undefined

    const words = (system.readText(`/proc/${pid}/cmdline`) ?? "").split("\0")
    if (!words.includes(socket)) return undefined

    return { pid, display: words[words.indexOf("-display") + 1] }
  }

  const forget = (socket: string): boolean => {
    const wasThere = system.exists(socket) || system.exists(pidFile)
    system.remove(pidFile)
    system.remove(socket)
    return wasThere
  }

  const exits = async (pid: number): Promise<boolean> => {
    for (let poll = 0; poll < stopPolls && system.processAlive(pid); poll += 1)
      await system.sleep(pollMs)
    return !system.processAlive(pid)
  }

  const stop = async (helper: RunningHelper, socket: string): Promise<boolean> => {
    system.terminate(helper.pid)
    if (!(await exits(helper.pid))) system.terminate(helper.pid, "SIGKILL")
    if (!(await exits(helper.pid))) return false

    forget(socket)
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

  const whyItMayNotBeShared = async (pid: number, socket: string): Promise<string | undefined> => {
    if (!(await socketOpens(socket))) return `x0vncserver didn't open its socket (see ${logFile})`

    const first = portsNow(pid, socket)
    await system.sleep(portSettleMs)
    const second = portsNow(pid, socket)
    if (first === undefined || second === undefined) return unchecked

    const port = [...first, ...second][0]
    return port === undefined
      ? undefined
      : `x0vncserver listens on TCP port ${port}, and the screen must only be shared on its socket`
  }

  const start = async (
    socket: string,
    shown: ShownScreen,
    scraper: string
  ): Promise<string | undefined> => {
    keepOwnFoldersPrivate(system, { socket })
    forget(socket)
    const command = [scraper, ...scraperArguments(shown.display, socket)]
    const pid = system.spawnDetached("env", [...asAssignments(shown.env), ...command], logFile)
    if (pid === undefined) return "x0vncserver couldn't be started"

    system.writeText(pidFile, `${pid}\n`)
    const why = await whyItMayNotBeShared(pid, socket)
    if (why === undefined) return undefined
    if (!(await stop({ pid, display: shown.display }, socket)))
      return `${why}; ${stillRunning(pid)}`

    return why
  }

  return { running, start, stop, forget, started }
}

export const asAssignments = (env: Readonly<Record<string, string>>): ReadonlyArray<string> =>
  Object.entries(env).map(([name, value]) => `${name}=${value}`)

const scraperArguments = (display: string, socket: string): ReadonlyArray<string> => [
  "-display",
  display,
  "-rfbunixpath",
  socket,
  "-rfbunixmode",
  "0600",
  "-rfbport",
  "-1",
  "-localhost",
  "-SecurityTypes",
  "None",
  "-AcceptSetDesktopSize=0"
]

const tcpPortsOfTheHelper: TcpPortsOf = (helper, socket) =>
  holdsUnixSocket(helper, socket) ? tcpPortsListenedOnBy(helper) : undefined
