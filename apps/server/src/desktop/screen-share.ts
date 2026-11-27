import { join } from "node:path"

import type { ScreenStatus } from "@codevisor/api"

import { privateSocket } from "../routes/private-socket.js"
import {
  SCREEN_ENTRY,
  withDisplayEntry,
  withoutDisplayEntry
} from "../routes/screen-sharing-config.js"
import {
  desktopSetup,
  SCREEN_SHARING_CONFIG_FILE,
  screenSetup
} from "../routes/screen-sharing-vnc.js"
import { HttpFailure } from "../server-context.js"
import { keepOwnFoldersPrivate, runtimeFolder } from "./desktop-layout.js"
import type { LocateSocket } from "./desktop-liveness.js"
import {
  installPlan,
  missingScreenPrograms,
  osRelease,
  runAsRoot,
  screenScraper,
  sudoKind
} from "./desktop-packages.js"
import type { DesktopSystem } from "./desktop-system.js"
import { holdsUnixSocket, tcpPortsListenedOnBy } from "./listening-ports.js"
import {
  accountsAtTheScreen,
  type GraphicalSession,
  ownGraphicalSession
} from "./screen-session.js"

export interface ScreenShare {
  readonly status: () => Promise<ScreenStatus>
  readonly installPackages: () => Promise<ScreenStatus>
  readonly setUp: () => Promise<ScreenStatus>
  readonly remove: () => Promise<ScreenStatus>
  readonly follow: () => Promise<void>
  readonly viewerJoined: () => void
}

export interface ScreenShareOptions {
  readonly system: DesktopSystem
  readonly dataDir: string
  readonly logsDir: string
  readonly changed: () => void
  readonly locate?: LocateSocket
  readonly tcpPortsOf?: (helper: number, socket: string) => ReadonlyArray<number> | undefined
  readonly now?: () => number
}

type X11Session = GraphicalSession & { readonly display: string }

const isOnX11 = (session: GraphicalSession): session is X11Session =>
  session.kind === "x11" && session.display !== undefined

interface Helper {
  readonly pid: number
  readonly display: string | undefined
}

const socketPollMs = 100
const socketPolls = 50
const stopPolls = 50
const portSettleMs = 1000
const notifyEveryMs = 30_000
const retryAfterMs = 30_000
const notRunning = "the helper that shares the screen isn't running"
const noScraper = "x0vncserver (TigerVNC's server for an existing screen) isn't installed"
const notX11 =
  "This account's session at the screen runs on Wayland, and Codevisor can only share X11 sessions so far."

export const makeScreenShare = (options: ScreenShareOptions): ScreenShare => {
  const { system, dataDir, changed } = options
  const locate = options.locate ?? privateSocket
  const tcpPortsOf = options.tcpPortsOf ?? tcpPortsOfTheHelper
  const now = options.now ?? Date.now
  const configPath = join(dataDir, SCREEN_SHARING_CONFIG_FILE)
  const pidFile = join(dataDir, "screen.pid")
  const logFile = join(options.logsDir, "screen.log")
  const socket = join(runtimeFolder(system), "codevisor-screen.sock")
  let seenAt: number | undefined
  let problem: string | undefined
  let retryAt: number | undefined
  let notifiedAt: number | undefined
  let last: Promise<unknown> = Promise.resolve()

  const oneAtATime = <Result>(work: () => Promise<Result>): Promise<Result> => {
    const run = last.then(work, work)
    last = run.catch(() => undefined)
    return run
  }

  const isSetUp = (): boolean => screenSetup(system.readText(configPath)) !== undefined

  const virtualDisplay = (): string | undefined => {
    const setup = desktopSetup(system.readText(configPath) ?? "")
    const display = setup.kind === "ready" ? setup.config.display : undefined
    return display === undefined ? undefined : `:${display}`
  }

  const session = (): GraphicalSession | undefined => {
    const found = ownGraphicalSession(system, {
      ignoreDisplay: virtualDisplay(),
      lookFirstAt: seenAt
    })
    seenAt = found?.process
    return found
  }

  const helper = (): Helper | undefined => {
    const pid = Number(system.readText(pidFile)?.trim() ?? "")
    if (!Number.isInteger(pid) || pid <= 0 || !system.processAlive(pid)) return undefined

    const words = (system.readText(`/proc/${pid}/cmdline`) ?? "").split("\0")
    if (!words.includes(socket)) return undefined

    return { pid, display: words[words.indexOf("-display") + 1] }
  }

  const stop = async (running: Helper): Promise<void> => {
    system.terminate(running.pid)
    for (let poll = 0; poll < stopPolls && system.processAlive(running.pid); poll += 1)
      await system.sleep(socketPollMs)
    forgetTheHelper()
    changed()
  }

  const forgetTheHelper = (): void => {
    system.remove(pidFile)
    system.remove(socket)
  }

  const socketOpens = async (): Promise<boolean> => {
    for (let poll = 0; poll < socketPolls; poll += 1) {
      if (locate(socket).problem === undefined) return true

      await system.sleep(socketPollMs)
    }
    return false
  }

  const whyItMayNotBeShared = async (pid: number): Promise<string | undefined> => {
    if (!(await socketOpens())) return `x0vncserver didn't open its socket (see ${logFile})`

    const first = tcpPortsOf(pid, socket)
    await system.sleep(portSettleMs)
    const ports = [...(first ?? []), ...(tcpPortsOf(pid, socket) ?? [])]
    if (first === undefined) return "couldn't check that x0vncserver stays off the network"
    if (ports.length > 0)
      return `x0vncserver listens on TCP port ${ports[0]}, and the screen must only be shared on its socket`

    return undefined
  }

  const startHelper = async (shown: X11Session, scraper: string): Promise<string | undefined> => {
    keepOwnFoldersPrivate(system, { socket })
    forgetTheHelper()
    const command = [scraper, ...scraperArguments(shown.display, socket)]
    const pid = system.spawnDetached("env", [...asAssignments(shown.env), ...command], logFile)
    if (pid === undefined) return "x0vncserver couldn't be started"

    system.writeText(pidFile, `${pid}\n`)
    const why = await whyItMayNotBeShared(pid)
    if (why !== undefined) await stop({ pid, display: shown.display })
    return why
  }

  const start = async (found: GraphicalSession): Promise<void> => {
    if (!isOnX11(found)) {
      problem = notX11
      return
    }

    const scraper = await screenScraper(system)
    problem = noScraper
    if (scraper !== undefined) problem = await startHelper(found, scraper)
    retryAt = problem === undefined ? undefined : now() + retryAfterMs
    changed()
  }

  const follow = async (): Promise<void> => {
    const running = helper()
    const found = isSetUp() ? session() : undefined
    if (running !== undefined && showsTheScreenOf(running, found)) return
    if (running !== undefined) await stop(running)
    if (found === undefined) return nothingToShare()
    if (retryAt === undefined || now() >= retryAt) await start(found)
  }

  const nothingToShare = (): void => {
    problem = undefined
    retryAt = undefined
    if (!system.exists(socket) && !system.exists(pidFile)) return

    forgetTheHelper()
    changed()
  }

  const others = async (): Promise<ReadonlyArray<string>> =>
    (await accountsAtTheScreen(system)).filter((account) => account !== system.account)

  const status = async (): Promise<ScreenStatus> => {
    const found = session()
    const seen = {
      missing: await missingScreenPrograms(system),
      others: await others(),
      ...(found === undefined ? {} : { session: found.kind }),
      ...(found?.display === undefined ? {} : { display: found.display })
    }
    if (!isSetUp()) return { state: "none", ...seen }
    if (helper() !== undefined && locate(socket).problem === undefined)
      return { state: "running", ...seen }
    if (found === undefined) return { state: "waiting", ...seen }

    return { state: "stopped", ...seen, problem: problem ?? notRunning }
  }

  const refuseWhatCannotBeShared = async (): Promise<void> => {
    const found = session()
    const there = await others()
    if (found === undefined && there.length > 0)
      throw new HttpFailure(409, someoneElseIsThere(there, system.account))
    if (found !== undefined && !isOnX11(found)) throw new HttpFailure(409, notX11)
  }

  const setUp = async (): Promise<ScreenStatus> => {
    await refuseWhatCannotBeShared()
    const missing = await missingScreenPrograms(system)
    if (missing.length > 0)
      throw new HttpFailure(
        409,
        `The screen can't be shared until these are installed: ${missing.join(", ")}`
      )

    const entry = { id: SCREEN_ENTRY, vnc: { socket, name: "Screen" }, service: "server" }
    system.writeText(configPath, withDisplayEntry(system.readText(configPath), entry))
    retryAt = undefined
    await follow()
    changed()
    return status()
  }

  const remove = async (): Promise<ScreenStatus> => {
    const rest = withoutDisplayEntry(system.readText(configPath), SCREEN_ENTRY)
    if (rest === undefined) system.remove(configPath)
    else system.writeText(configPath, rest)
    await follow()
    changed()
    return status()
  }

  const installPackages = async (): Promise<ScreenStatus> => {
    const plan = await installPlan(system, osRelease(system))
    if (plan === undefined)
      throw new HttpFailure(501, "Codevisor doesn't know how to install packages on this system")
    if ((await sudoKind(system)) !== "passwordless")
      throw new HttpFailure(403, "Installing packages needs an administrator on this machine")

    const ran = await runAsRoot(system, plan.screenCommands)
    if (!ran.ok) throw new HttpFailure(502, `Installing packages failed:\n${ran.output}`)

    return status()
  }

  const viewerJoined = (): void => {
    const found = session()
    const isTooSoon = notifiedAt !== undefined && now() - notifiedAt < notifyEveryMs
    if (found === undefined || isTooSoon) return

    notifiedAt = now()
    void system
      .run("env", [...asAssignments(found.env), "notify-send", "-a", "Codevisor", ...notice])
      .catch(() => undefined)
  }

  return {
    status,
    installPackages: () => oneAtATime(installPackages),
    setUp: () => oneAtATime(setUp),
    remove: () => oneAtATime(remove),
    follow: () => oneAtATime(follow),
    viewerJoined
  }
}

const notice = ["Codevisor", "Someone started viewing this screen."]

const showsTheScreenOf = (running: Helper, found: GraphicalSession | undefined): boolean =>
  found?.kind === "x11" && running.display === found.display

export const someoneElseIsThere = (accounts: ReadonlyArray<string>, account: string): string =>
  `${accounts.join(" and ")} ${accounts.length === 1 ? "is" : "are"} logged in at this machine's screen, and Codevisor runs as ${account} here, so it can't share that screen. Set up a separate desktop instead: codevisor desktop setup`

const asAssignments = (env: Readonly<Record<string, string>>): ReadonlyArray<string> =>
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

const tcpPortsOfTheHelper = (helper: number, socket: string): ReadonlyArray<number> | undefined =>
  holdsUnixSocket(helper, socket) ? tcpPortsListenedOnBy(helper) : undefined
