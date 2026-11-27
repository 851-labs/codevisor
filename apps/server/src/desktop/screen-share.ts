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
import { runtimeFolder } from "./desktop-layout.js"
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
import type { RootCommand } from "./old-desktop.js"
import {
  asAssignments,
  type RunningHelper,
  screenHelpers,
  type ShownScreen,
  type TcpPortsOf
} from "./screen-helper.js"
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
  readonly tcpPortsOf?: TcpPortsOf
  readonly now?: () => number
}

type X11Session = GraphicalSession & ShownScreen

const notifyEveryMs = 30_000
const retryAfterMs = 30_000
const installing = "Installing packages"
const notRunning = "the helper that shares the screen isn't running"
const noScraper = "x0vncserver (TigerVNC's server for an existing screen) isn't installed"

export const waylandIsNotShared =
  "This account's session at the screen runs on Wayland, and Codevisor can only share X11 sessions so far."

export const someoneElseIsThere = (accounts: ReadonlyArray<string>, account: string): string =>
  `${accounts.join(" and ")} ${accounts.length === 1 ? "is" : "are"} logged in at this machine's screen, and Codevisor runs as ${account} here, so it can't share that screen. Set up a separate desktop instead: codevisor desktop setup`

export const makeScreenShare = (options: ScreenShareOptions): ScreenShare => {
  const { system, dataDir, changed } = options
  const locate = options.locate ?? privateSocket
  const now = options.now ?? Date.now
  const configPath = join(dataDir, SCREEN_SHARING_CONFIG_FILE)
  const helpers = screenHelpers({
    system,
    pidFile: join(dataDir, "screen.pid"),
    logFile: join(options.logsDir, "screen.log"),
    locate,
    tcpPortsOf: options.tcpPortsOf
  })
  let seenAt: number | undefined
  let problem: string | undefined
  let retryAt: number | undefined
  let notifiedAt: number | undefined
  let busy: string | undefined
  let failure: string | undefined
  let last: Promise<unknown> = Promise.resolve()

  const oneAtATime = <Result>(work: () => Promise<Result>): Promise<Result> => {
    const run = last.then(work, work)
    last = run.catch(() => undefined)
    return run
  }

  const recordedSocket = (): string | undefined => screenSetup(system.readText(configPath))?.socket

  const socketToUse = (): string =>
    recordedSocket() ?? join(runtimeFolder(system), "codevisor-screen.sock")

  const virtualDisplay = (): string | undefined => {
    const setup = desktopSetup(system.readText(configPath) ?? "")
    const display = setup.kind === "ready" ? setup.config.display : undefined
    return display === undefined ? undefined : `:${display}`
  }

  const sessionByItsProcesses = (): GraphicalSession | undefined => {
    const found = ownGraphicalSession(system, {
      ignoreDisplay: virtualDisplay(),
      lookFirstAt: seenAt
    })
    seenAt = found?.process
    return found
  }

  const session = async (): Promise<GraphicalSession | undefined> => {
    const found = sessionByItsProcesses()
    if (found === undefined) return undefined

    const loggedIn = await accountsAtTheScreen(system)
    return loggedIn === undefined || loggedIn.includes(system.account) ? found : undefined
  }

  const others = async (): Promise<ReadonlyArray<string>> =>
    ((await accountsAtTheScreen(system)) ?? []).filter((account) => account !== system.account)

  const start = async (socket: string, found: GraphicalSession): Promise<void> => {
    problem = await whyItDidNotStart(socket, found)
    retryAt = problem === undefined ? undefined : now() + retryAfterMs
    changed()
  }

  const whyItDidNotStart = async (
    socket: string,
    found: GraphicalSession
  ): Promise<string | undefined> => {
    if (!isOnX11(found)) return waylandIsNotShared

    const scraper = await screenScraper(system)
    return scraper === undefined ? noScraper : helpers.start(socket, found, scraper)
  }

  const stop = async (running: RunningHelper, socket: string): Promise<void> => {
    await helpers.stop(running, socket)
    changed()
  }

  const nothingToShare = (socket: string): void => {
    problem = undefined
    retryAt = undefined
    if (helpers.forget(socket)) changed()
  }

  const follow = async (): Promise<void> => {
    const recorded = recordedSocket()
    const socket = recorded ?? socketToUse()
    const running = helpers.running(socket)
    if (running !== undefined && recorded !== undefined && isStillShown(running)) return
    if (running !== undefined) await stop(running, socket)
    if (recorded === undefined) return nothingToShare(socket)
    if (retryAt !== undefined && now() < retryAt) return

    const found = await session()
    if (found === undefined) return nothingToShare(socket)

    await start(socket, found)
  }

  const isStillShown = (running: RunningHelper): boolean => {
    const found = sessionByItsProcesses()
    return found?.kind === "x11" && running.display === found.display
  }

  const sudoForAnInstall = async (missing: ReadonlyArray<string>) => {
    if (missing.length === 0) return {}

    return { sudo: await sudoKind(system) }
  }

  const seen = async (found: GraphicalSession | undefined) => {
    const missing = await missingScreenPrograms(system)
    if (missing.length === 0) failure = undefined
    return {
      missing,
      others: await others(),
      ...(await sudoForAnInstall(missing)),
      ...(busy === undefined ? {} : { busy }),
      ...(failure === undefined ? {} : { failure }),
      ...(found === undefined ? {} : { session: found.kind }),
      ...(found?.display === undefined ? {} : { display: found.display })
    }
  }

  const status = async (): Promise<ScreenStatus> => {
    const found = await session()
    const about = await seen(found)
    const socket = recordedSocket()
    if (socket === undefined) return { state: "none", ...about }
    if (helpers.running(socket) !== undefined && locate(socket).problem === undefined)
      return { state: "running", ...about }
    if (found === undefined) return { state: "waiting", ...about }

    return { state: "stopped", ...about, problem: problem ?? notRunning }
  }

  const refuseWhatCannotBeShared = async (): Promise<void> => {
    const found = await session()
    const there = await others()
    if (found === undefined && there.length > 0)
      throw new HttpFailure(409, someoneElseIsThere(there, system.account))
    if (found !== undefined && !isOnX11(found)) throw new HttpFailure(409, waylandIsNotShared)
  }

  const setUp = async (): Promise<ScreenStatus> => {
    await refuseWhatCannotBeShared()
    const missing = await missingScreenPrograms(system)
    if (missing.length > 0)
      throw new HttpFailure(
        409,
        `The screen can't be shared until these are installed: ${missing.join(", ")}`
      )

    const entry = {
      id: SCREEN_ENTRY,
      vnc: { socket: socketToUse(), name: "Screen" },
      service: "server"
    }
    system.writeText(configPath, withDisplayEntry(system.readText(configPath), entry))
    retryAt = undefined
    await follow()
    changed()
    return status()
  }

  const remove = async (): Promise<ScreenStatus> => {
    const socket = socketToUse()
    const running = helpers.running(socket)
    const rest = withoutDisplayEntry(system.readText(configPath), SCREEN_ENTRY)
    if (rest === undefined) system.remove(configPath)
    else system.writeText(configPath, rest)
    if (running !== undefined) await helpers.stop(running, socket)
    nothingToShare(socket)
    changed()
    return status()
  }

  const installInTheBackground = (commands: ReadonlyArray<RootCommand>): void => {
    busy = installing
    failure = undefined
    void runAsRoot(system, commands)
      .then((ran) => {
        if (!ran.ok) failure = `${installing} failed:\n${ran.output}`
      })
      .catch((cause: unknown) => {
        failure = cause instanceof Error ? cause.message : String(cause)
      })
      .finally(() => {
        busy = undefined
      })
  }

  const installPackages = async (): Promise<ScreenStatus> => {
    const plan = await installPlan(system, osRelease(system))
    if (plan === undefined)
      throw new HttpFailure(501, "Codevisor doesn't know how to install packages on this system")
    if (busy !== undefined) return status()
    if ((await sudoKind(system)) !== "passwordless")
      throw new HttpFailure(403, `${installing} needs an administrator on this machine`)

    installInTheBackground(plan.screenCommands)
    return status()
  }

  const viewerJoined = (): void => {
    const found = sessionByItsProcesses()
    const isTooSoon = notifiedAt !== undefined && now() - notifiedAt < notifyEveryMs
    if (found === undefined || isTooSoon) return

    notifiedAt = now()
    void system
      .run("env", [...asAssignments(found.env), "notify-send", "-a", "Codevisor", ...notice])
      .catch(() => undefined)
  }

  return {
    status,
    installPackages,
    setUp: () => oneAtATime(setUp),
    remove: () => oneAtATime(remove),
    follow: () => oneAtATime(follow),
    viewerJoined
  }
}

const notice = ["Codevisor", "Someone started viewing this screen."]

const isOnX11 = (session: GraphicalSession): session is X11Session =>
  session.kind === "x11" && session.display !== undefined
