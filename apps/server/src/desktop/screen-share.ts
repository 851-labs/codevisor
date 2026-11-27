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
  type ScreenProgram,
  sudoKind
} from "./desktop-packages.js"
import type { DesktopSystem } from "./desktop-system.js"
import type { RootCommand } from "./old-desktop.js"
import { asAssignments, type ScreenKind, type ShownScreen } from "./screen-commands.js"
import {
  type RunningHelper,
  screenHelpers,
  stillRunning,
  type TcpPortsOf
} from "./screen-helper.js"
import { knownScreenPrograms, noScraperFor, tooOldText } from "./screen-programs.js"
import {
  accountsAtTheScreen,
  type AtTheScreen,
  type GraphicalSession,
  ownGraphicalSession,
  sameDisplay
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
  readonly viewerJoined: () => Promise<void>
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

type Present = ReadonlyArray<AtTheScreen> | undefined

interface Known<Value> {
  readonly value: Value
  readonly at: number
}

const notifyEveryMs = 30_000
const retryAfterMs = 30_000
const programsStayKnownMs = 30_000
const diesTooSoonMs = 30_000
const diedSoon = "the screen's VNC server stopped right after it started; see its log"
const installing = "Installing packages"
const notRunning = "the helper that shares the screen isn't running"

export const waylandIsNotShared =
  "This account's session at the screen runs a Wayland desktop that Codevisor can't share yet; it shares X11 sessions and wlroots ones such as Sway and Hyprland."

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
  let retryFor: number | undefined
  let notifiedAt: number | undefined
  const installed = knownScreenPrograms(system, now)
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

  const sessionByItsProcesses = (own?: AtTheScreen): GraphicalSession | undefined => {
    const found = ownGraphicalSession(system, {
      ignoreDisplay: virtualDisplay(),
      lookFirstAt: seenAt,
      session: own?.session,
      display: own?.display,
      type: own?.type
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

    const own = ownEntry(present)
    const found = sessionByItsProcesses(own)
    return found === undefined ? undefined : asLogindSaysItIs(found, own?.type)
  }

  const othersGiven = (present: Present): ReadonlyArray<string> =>
    (present ?? []).map((entry) => entry.account).filter((account) => account !== system.account)

  const isFresh = <Value>(known: Known<Value> | undefined): known is Known<Value> =>
    known !== undefined && now() - known.at < programsStayKnownMs

  const kindsWanted = async (
    found: GraphicalSession | undefined
  ): Promise<ReadonlyArray<ScreenKind>> => {
    if (found === undefined) return installed.kindsOfTheMachine()

    const shown = shownFrom(found)
    return shown === undefined ? [] : [shown.kind]
  }

  const missingGiven = async (
    found: GraphicalSession | undefined
  ): Promise<ReadonlyArray<ScreenProgram>> => installed.missing(await kindsWanted(found))

  const sudo = async (): Promise<DesktopSudo> => {
    if (isFresh(knownSudo)) return knownSudo.value

    knownSudo = { value: await sudoKind(system), at: now() }
    return knownSudo.value
  }

  const whyItDidNotStart = async (
    socket: string,
    found: GraphicalSession
  ): Promise<string | undefined> => {
    const shown = shownFrom(found)
    if (shown === undefined) return waylandIsNotShared

    const scraper = (await installed.programs([shown.kind])).scrapers.get(shown.kind)
    if (scraper === undefined) return noScraperFor(shown.kind)
    if (scraper.tooOld !== undefined) return tooOldText(scraper)

    return helpers.start(socket, shown, scraper)
  }

  const start = async (socket: string, found: GraphicalSession): Promise<void> => {
    problem = await whyItDidNotStart(socket, found)
    retryAt = problem === undefined ? undefined : now() + retryAfterMs
    retryFor = found.process
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

  const noteAQuickDeath = (found: GraphicalSession | undefined): void => {
    const diedSoonAfterStarting = startedAt !== undefined && now() - startedAt < diesTooSoonMs
    startedAt = undefined
    if (!diedSoonAfterStarting) return

    problem = diedSoon
    retryAt = now() + retryAfterMs
    retryFor = found?.process
  }

  const waitsToRetry = (found: GraphicalSession): boolean =>
    retryAt !== undefined && now() < retryAt && retryFor === found.process

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
    showsTheSame(running, found) &&
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
    if (running === undefined) noteAQuickDeath(found)
    if (found === undefined) return nothingToShare(socket)
    if (waitsToRetry(found)) return

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
    const missing = await missingGiven(found)
    const shown = found === undefined ? undefined : shownFrom(found)
    const display = shown?.shows ?? found?.display
    if (missing.length === 0) failure = undefined
    return {
      missing,
      others: othersGiven(present),
      ...(await sudoToReport(missing, asked)),
      ...(busy === undefined ? {} : { busy }),
      ...(failure === undefined ? {} : { failure }),
      ...(found === undefined ? {} : { session: found.kind }),
      ...(display === undefined ? {} : { display })
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
    if (found !== undefined && isSharing(socket)) return { state: "running", ...seen }
    if (found === undefined) return { state: "waiting", ...seen }

    return { state: "stopped", ...seen, problem: problem ?? notRunning }
  }

  const refuseWhatCannotBeShared = (present: Present): void => {
    const found = sessionGiven(present)
    const there = othersGiven(present)
    if (found === undefined && there.length > 0)
      throw new HttpFailure(409, someoneElseIsThere(there, system.account))
    if (found !== undefined && shownFrom(found) === undefined)
      throw new HttpFailure(409, waylandIsNotShared)
  }

  const refuseAConfigItCannotRead = (): void => {
    const text = system.readText(configPath)
    if (text !== undefined && !isAConfig(text)) throw new HttpFailure(409, unreadableConfig)
  }

  const setUp = async (): Promise<ScreenStatus> => {
    refuseAConfigItCannotRead()
    const present = await accountsAtTheScreen(system)
    refuseWhatCannotBeShared(present)
    installed.checkAgain()
    const found = sessionGiven(present)
    const missing = await missingGiven(found)
    if (missing.length > 0)
      throw new HttpFailure(
        409,
        `The screen can't be shared until these are installed: ${missing.join(", ")}`
      )
    const tooOld = await installed.tooOld(await kindsWanted(found))
    if (tooOld !== undefined) throw new HttpFailure(409, tooOld)

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

    const running = helpers.running()
    if (running !== undefined && !(await stop(running)))
      throw new HttpFailure(500, stillRunning(running.pid))

    forgetTheScreen()
    nothingToShare(socket)
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
        installed.checkAgain()
      })
  }

  const commandsToInstall = async (): Promise<ReadonlyArray<RootCommand>> => {
    const plan = await installPlan(system, osRelease(system))
    if (plan === undefined)
      throw new HttpFailure(501, "Codevisor doesn't know how to install packages on this system")
    if ((await sudoKind(system)) !== "passwordless")
      throw new HttpFailure(403, `${installing} needs an administrator on this machine`)

    const found = sessionGiven(await accountsAtTheScreen(system))
    if (found !== undefined && shownFrom(found) === undefined)
      throw new HttpFailure(409, waylandIsNotShared)

    installed.checkAgain()
    return plan.screenCommands(await missingGiven(found))
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

  const viewerJoined = async (): Promise<void> => {
    const isTooSoon = notifiedAt !== undefined && now() - notifiedAt < notifyEveryMs
    if (isTooSoon) return

    notifiedAt = now()
    const found = sessionGiven(await accountsAtTheScreen(system).catch(() => []))
    if (found === undefined) {
      notifiedAt = undefined
      return
    }

    const shown = [...asAssignments(found.env), "notify-send", "-a", "Codevisor", ...notice]
    await system.run("env", shown).catch(() => undefined)
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

export const shownFrom = (session: GraphicalSession): ShownScreen | undefined => {
  const wayland = session.env["WAYLAND_DISPLAY"]
  if (session.kind === "wlroots" && wayland !== undefined)
    return { kind: "wlroots", shows: wayland, env: session.env }
  if (session.kind !== "x11" || session.display === undefined) return undefined

  return { kind: "x11", shows: session.display, env: session.env }
}

const showsTheSame = (running: RunningHelper, found: GraphicalSession | undefined): boolean => {
  const shown = found === undefined ? undefined : shownFrom(found)
  if (shown === undefined) return false

  return shown.kind === "x11"
    ? sameDisplay(running.shows, shown.shows)
    : running.shows === shown.shows
}
