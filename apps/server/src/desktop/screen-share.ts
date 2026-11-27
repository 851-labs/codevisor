import { createHash } from "node:crypto"
import { join } from "node:path"

import type { DesktopSudo, ScreenStatus } from "@codevisor/api"

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
  osRelease,
  runAsRoot,
  type ScreenPrograms,
  screenPrograms,
  sudoKind
} from "./desktop-packages.js"
import type { DesktopSystem } from "./desktop-system.js"
import type { RootCommand } from "./old-desktop.js"
import {
  asAssignments,
  type RunningHelper,
  screenHelpers,
  type ShownScreen,
  stillRunning,
  type TcpPortsOf
} from "./screen-helper.js"
import {
  accountsAtTheScreen,
  type AtTheScreen,
  type GraphicalSession,
  ownGraphicalSession
} from "./screen-session.js"

export interface ScreenStatusOptions {
  readonly askSudo?: boolean
}

export interface ScreenShare {
  readonly status: (options?: ScreenStatusOptions) => Promise<ScreenStatus>
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
type Present = ReadonlyArray<AtTheScreen> | undefined

interface Known<Value> {
  readonly value: Value
  readonly at: number
}

const notifyEveryMs = 30_000
const retryAfterMs = 30_000
const programsStayKnownMs = 30_000
const diesTooSoonMs = 30_000
const diedSoon = "x0vncserver stopped right after it started; see its log"
const installing = "Installing packages"
const notRunning = "the helper that shares the screen isn't running"
const noScraper = "x0vncserver (TigerVNC's server for an existing screen) isn't installed"

export const waylandIsNotShared =
  "This account's session at the screen runs on Wayland, and Codevisor can only share X11 sessions so far."

export const someoneElseIsThere = (accounts: ReadonlyArray<string>, account: string): string =>
  `${accounts.join(" and ")} ${accounts.length === 1 ? "is" : "are"} logged in at this machine's screen, and Codevisor runs as ${account} here, so it can't share that screen. Set up a separate desktop instead: codevisor desktop setup`

export const screenSocketName = (dataDir: string): string =>
  `codevisor-screen-${createHash("sha256").update(dataDir).digest("hex").slice(0, 12)}.sock`

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
  let installed: Known<ScreenPrograms> | undefined
  let knownSudo: Known<DesktopSudo> | undefined
  let startedAt: number | undefined
  let busy: string | undefined
  let failure: string | undefined
  let last: Promise<unknown> = Promise.resolve()

  const oneAtATime = <Result>(work: () => Promise<Result>): Promise<Result> => {
    const run = last.then(work, work)
    last = run.catch(() => undefined)
    return run
  }

  const recordedSocket = (): string | undefined => screenSetup(system.readText(configPath))?.socket

  const ownSocket = (): string => join(runtimeFolder(system), screenSocketName(dataDir))

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

  const ownEntry = (present: Present): AtTheScreen | undefined =>
    present?.find((entry) => entry.account === system.account)

  const isAtTheScreen = (present: Present): boolean =>
    present === undefined || ownEntry(present) !== undefined

  const sessionGiven = (present: Present): GraphicalSession | undefined => {
    if (!isAtTheScreen(present)) return undefined

    const found = sessionByItsProcesses()
    return found === undefined ? undefined : asLogindSaysItIs(found, ownEntry(present)?.type)
  }

  const othersGiven = (present: Present): ReadonlyArray<string> =>
    (present ?? []).map((entry) => entry.account).filter((account) => account !== system.account)

  const isFresh = <Value>(known: Known<Value> | undefined): known is Known<Value> =>
    known !== undefined && now() - known.at < programsStayKnownMs

  const programs = async (): Promise<ScreenPrograms> => {
    if (isFresh(installed)) return installed.value

    const found = await screenPrograms(system)
    installed = found.missing.length === 0 ? { value: found, at: now() } : undefined
    return found
  }

  const sudo = async (): Promise<DesktopSudo> => {
    if (isFresh(knownSudo)) return knownSudo.value

    knownSudo = { value: await sudoKind(system), at: now() }
    return knownSudo.value
  }

  const checkProgramsAgain = (): void => {
    installed = undefined
  }

  const whyItDidNotStart = async (
    socket: string,
    found: GraphicalSession
  ): Promise<string | undefined> => {
    if (!isOnX11(found)) return waylandIsNotShared

    const { scraper } = await programs()
    if (scraper === undefined) return noScraper

    return helpers.start(socket, found, scraper)
  }

  const start = async (socket: string, found: GraphicalSession): Promise<void> => {
    problem = await whyItDidNotStart(socket, found)
    retryAt = problem === undefined ? undefined : now() + retryAfterMs
    startedAt = problem === undefined ? now() : undefined
    changed()
  }

  const stop = async (running: RunningHelper): Promise<boolean> => {
    startedAt = undefined
    const stopped = await helpers.stop(running)
    if (!stopped) problem = stillRunning(running.pid)
    changed()
    return stopped
  }

  const noteAQuickDeath = (): void => {
    const diedSoonAfterStarting = startedAt !== undefined && now() - startedAt < diesTooSoonMs
    startedAt = undefined
    if (!diedSoonAfterStarting) return

    problem = diedSoon
    retryAt = now() + retryAfterMs
  }

  const nothingToShare = (socket: string): void => {
    problem = undefined
    retryAt = undefined
    startedAt = undefined
    if (helpers.forget(socket)) changed()
  }

  const isStillShown = (
    running: RunningHelper,
    found: GraphicalSession | undefined,
    socket: string
  ): boolean =>
    running.socket === socket &&
    found?.kind === "x11" &&
    running.display === found.display &&
    locate(socket).problem === undefined

  const stopWhatThisServerStarted = async (): Promise<void> => {
    problem = undefined
    retryAt = undefined
    const running = helpers.running()
    if (running !== undefined) await stop(running)
    else if (helpers.started()) helpers.forget(ownSocket())
  }

  const follow = async (): Promise<void> => {
    const socket = recordedSocket()
    if (socket === undefined) return stopWhatThisServerStarted()

    const found = sessionGiven(await accountsAtTheScreen(system))
    const running = helpers.running()
    if (running !== undefined && isStillShown(running, found, socket)) return
    if (running !== undefined && !(await stop(running))) return
    if (running === undefined) noteAQuickDeath()
    if (found === undefined) return nothingToShare(socket)
    if (retryAt !== undefined && now() < retryAt) return

    await start(socket, found)
  }

  const sudoToReport = async (
    missing: ReadonlyArray<string>,
    asked: ScreenStatusOptions
  ): Promise<{ sudo?: DesktopSudo }> => {
    if (missing.length === 0 || asked.askSudo !== true) return {}

    return { sudo: await sudo() }
  }

  const about = async (
    present: Present,
    found: GraphicalSession | undefined,
    asked: ScreenStatusOptions
  ) => {
    const { missing } = await programs()
    if (missing.length === 0) failure = undefined
    return {
      missing,
      others: othersGiven(present),
      ...(await sudoToReport(missing, asked)),
      ...(busy === undefined ? {} : { busy }),
      ...(failure === undefined ? {} : { failure }),
      ...(found === undefined ? {} : { session: found.kind }),
      ...(found?.display === undefined ? {} : { display: found.display })
    }
  }

  const isSharing = (socket: string): boolean =>
    helpers.running()?.socket === socket && locate(socket).problem === undefined

  const status = async (asked: ScreenStatusOptions = {}): Promise<ScreenStatus> => {
    const present = await accountsAtTheScreen(system)
    const found = sessionGiven(present)
    const seen = await about(present, found, asked)
    const socket = recordedSocket()
    if (socket === undefined) return { state: "none", ...seen }
    if (isSharing(socket)) return { state: "running", ...seen }
    if (found === undefined) return { state: "waiting", ...seen }

    return { state: "stopped", ...seen, problem: problem ?? notRunning }
  }

  const refuseWhatCannotBeShared = (present: Present): void => {
    const found = sessionGiven(present)
    const there = othersGiven(present)
    if (found === undefined && there.length > 0)
      throw new HttpFailure(409, someoneElseIsThere(there, system.account))
    if (found !== undefined && !isOnX11(found)) throw new HttpFailure(409, waylandIsNotShared)
  }

  const refuseAConfigItCannotRead = (): void => {
    const text = system.readText(configPath)
    if (text !== undefined && !isAConfig(text)) throw new HttpFailure(409, unreadableConfig)
  }

  const setUp = async (): Promise<ScreenStatus> => {
    refuseAConfigItCannotRead()
    refuseWhatCannotBeShared(await accountsAtTheScreen(system))
    checkProgramsAgain()
    const { missing } = await programs()
    if (missing.length > 0)
      throw new HttpFailure(
        409,
        `The screen can't be shared until these are installed: ${missing.join(", ")}`
      )

    const socket = recordedSocket() ?? ownSocket()
    const entry = { id: SCREEN_ENTRY, vnc: { socket, name: "Screen" }, service: "server" }
    system.writeText(configPath, withDisplayEntry(system.readText(configPath), entry))
    retryAt = undefined
    await follow()
    changed()
    return status()
  }

  const forgetTheScreen = (): void => {
    const rest = withoutDisplayEntry(system.readText(configPath), SCREEN_ENTRY)
    if (rest === undefined) system.remove(configPath)
    else system.writeText(configPath, rest)
  }

  const remove = async (): Promise<ScreenStatus> => {
    const socket = recordedSocket()
    if (socket === undefined) return status()

    forgetTheScreen()
    const running = helpers.running()
    if (running !== undefined) await stop(running)
    else nothingToShare(socket)
    changed()
    return status()
  }

  const installInTheBackground = (commands: ReadonlyArray<RootCommand>): void => {
    void runAsRoot(system, commands)
      .then((ran) => {
        if (!ran.ok) failure = `${installing} failed:\n${ran.output}`
      })
      .catch((cause: unknown) => {
        failure = cause instanceof Error ? cause.message : String(cause)
      })
      .finally(() => {
        busy = undefined
        checkProgramsAgain()
      })
  }

  const commandsToInstall = async (): Promise<ReadonlyArray<RootCommand>> => {
    const plan = await installPlan(system, osRelease(system))
    if (plan === undefined)
      throw new HttpFailure(501, "Codevisor doesn't know how to install packages on this system")
    if ((await sudoKind(system)) !== "passwordless")
      throw new HttpFailure(403, `${installing} needs an administrator on this machine`)

    return plan.screenCommands
  }

  const installPackages = async (): Promise<ScreenStatus> => {
    if (busy !== undefined) return status()

    busy = installing
    failure = undefined
    try {
      installInTheBackground(await commandsToInstall())
    } catch (cause) {
      busy = undefined
      throw cause
    }
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
const unreadableConfig =
  "screen-sharing.json in the server's data folder can't be read as a config, so Codevisor won't change it. Fix or remove it, then run this again."

const isAConfig = (text: string): boolean => {
  try {
    const parsed: unknown = JSON.parse(text)
    return typeof parsed === "object" && parsed !== null && !Array.isArray(parsed)
  } catch {
    return false
  }
}

const asLogindSaysItIs = (found: GraphicalSession, type: string | undefined): GraphicalSession => {
  if (type === "wayland" && found.kind === "x11") return { ...found, kind: "wayland" }
  if (type === "x11" && found.kind !== "x11" && found.display !== undefined)
    return { ...found, kind: "x11" }

  return found
}

const isOnX11 = (session: GraphicalSession): session is X11Session =>
  session.kind === "x11" && session.display !== undefined
