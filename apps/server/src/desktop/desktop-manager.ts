import { join } from "node:path"

import type { DesktopState, DesktopStatus, DesktopSudo } from "@codevisor/api"

import { type PrivateSocket, privateSocket } from "../routes/private-socket.js"
import {
  type DesktopSetup,
  desktopSetup,
  SCREEN_SHARING_CONFIG_FILE
} from "../routes/screen-sharing-vnc.js"
import { HttpFailure } from "../server-context.js"
import {
  DESKTOP_SIZE,
  desktopLayout,
  type DesktopLayout,
  displayIsOursOrFree,
  freeDisplay
} from "./desktop-layout.js"
import {
  installCommands,
  missingPrograms,
  osRelease,
  runAsRoot,
  sudoKind
} from "./desktop-packages.js"
import {
  type DesktopService,
  desktopServices,
  type DesktopServices,
  type RunnerCommand
} from "./desktop-service.js"
import type { DesktopSystem } from "./desktop-system.js"
import { oldDesktop, type RootCommand } from "./old-desktop.js"

export interface DesktopManager {
  readonly status: () => Promise<DesktopStatus>
  readonly installPackages: () => Promise<DesktopStatus>
  readonly replaceOld: () => Promise<DesktopStatus>
  readonly start: (options?: StartOptions) => Promise<DesktopStatus>
  readonly remove: () => Promise<DesktopStatus>
  readonly resume: () => Promise<void>
}

export interface StartOptions {
  readonly replaceUnmanaged?: boolean
}

export interface DesktopManagerOptions {
  readonly system: DesktopSystem
  readonly dataDir: string
  readonly logsDir: string
  readonly runner: RunnerCommand
  readonly changed: () => void
  readonly locate?: (configured: string) => PrivateSocket
}

interface Shared {
  readonly state: DesktopState
  readonly display?: number
  readonly problem?: string
}

const startPollMs = 250
const startPolls = 120
const steadyPolls = 10
const installing = "Installing packages"
const anotherServers =
  "Another Codevisor server on this account already runs a desktop (codevisor-desktop.service). Remove that desktop first."
const unmanaged =
  "A desktop that Codevisor didn't set up is shared from this machine. Replacing it has to be asked for."

export const makeDesktopManager = (options: DesktopManagerOptions): DesktopManager => {
  const { system, dataDir, changed } = options
  const locate = options.locate ?? privateSocket
  const configPath = join(dataDir, SCREEN_SHARING_CONFIG_FILE)
  const services = (): Promise<DesktopServices> => desktopServices(system, options.runner, options)
  const service = async (): Promise<DesktopService> => (await services()).current
  let busy: string | undefined
  let failure: string | undefined
  let knownSudo: DesktopSudo | undefined
  let last: Promise<unknown> = Promise.resolve()

  const oneAtATime = <Result>(work: () => Promise<Result>): Promise<Result> => {
    const run = last.then(work, work)
    last = run.catch(() => undefined)
    return run
  }

  const unlessBusy = <Result>(work: () => Promise<Result>): Promise<Result> => {
    if (busy !== undefined)
      return Promise.reject(
        new HttpFailure(409, `${busy} is still going on. Try again when it is done.`)
      )

    failure = undefined
    return oneAtATime(work)
  }

  const setUp = (): DesktopSetup => {
    const text = system.readText(configPath)
    return text === undefined ? { kind: "absent" } : desktopSetup(text)
  }

  const recordedService = (): string | undefined => {
    try {
      const config: unknown = JSON.parse(system.readText(configPath) ?? "")
      const isRecorded = typeof config === "object" && config !== null && "service" in config
      return isRecorded && typeof config.service === "string" ? config.service : undefined
    } catch {
      return undefined
    }
  }

  const shared = (): Shared => {
    const setup = setUp()
    if (setup.kind === "outdated") return { state: "outdated" }
    if (setup.kind !== "ready") return { state: "none" }

    const socket = locate(setup.config.socket)
    const display = setup.config.display === undefined ? {} : { display: setup.config.display }
    if (socket.problem === undefined) return { state: "running", ...display }

    return { state: "stopped", ...display, problem: socket.detail }
  }

  const sharedBy = (runs: DesktopService): Shared => {
    const live = shared()
    const processIsGone =
      runs.kind === "process" && recordedService() === "process" && !runs.isSetUp()
    if (live.state !== "running" || !processIsGone) return live

    return { ...live, state: "stopped", problem: "the desktop's process isn't running" }
  }

  const sudoForARootStep = async (pending: boolean): Promise<DesktopSudo | undefined> => {
    if (!pending) return undefined
    if (busy === undefined || knownSudo === undefined) knownSudo = await sudoKind(system)

    return knownSudo
  }

  const status = async (): Promise<DesktopStatus> => {
    const release = osRelease(system)
    const { current: runs, other } = await services()
    const install = await installCommands(system, release)
    const old = oldDesktop(system)
    const startsAtBoot = await runs.startsAtBoot()
    const needsLinger = runs.kind === "systemd-user" && !startsAtBoot
    const missing = await missingPrograms(system)
    if (missing.length === 0) failure = undefined
    const sudo = await sudoForARootStep(missing.length > 0 || old !== undefined)
    const live = sharedBy(runs)
    return {
      ...live,
      managed: recordedService() !== undefined || runs.isSetUp() || other.isSetUp(),
      keepsRunning: live.state === "running" && runs.isSetUp(),
      ...(busy === undefined ? {} : { busy }),
      ...(failure === undefined ? {} : { failure }),
      account: system.account,
      system: release.name,
      missing,
      ...(install === undefined ? {} : { packageManager: "apt" }),
      ...(sudo === undefined ? {} : { sudo }),
      ...(old === undefined ? {} : { oldDesktop: { units: old.units } }),
      startsAtBoot,
      ...(needsLinger ? { startAtBootHint: `sudo loginctl enable-linger ${system.account}` } : {}),
      logHint: runs.logHint
    }
  }

  const requirePasswordlessSudo = async (what: string): Promise<void> => {
    knownSudo = await sudoKind(system)
    if (knownSudo !== "passwordless")
      throw new HttpFailure(403, `${what} needs an administrator on this machine`)
  }

  const asRoot = async (what: string, commands: ReadonlyArray<RootCommand>): Promise<void> => {
    const ran = await runAsRoot(system, commands)
    if (!ran.ok) throw new HttpFailure(502, `${what} failed:\n${ran.output}`)
  }

  const installInTheBackground = (commands: ReadonlyArray<RootCommand>): void => {
    busy = installing
    failure = undefined
    void oneAtATime(() => asRoot(installing, commands))
      .catch((cause: unknown) => {
        failure = cause instanceof Error ? cause.message : String(cause)
      })
      .finally(() => {
        busy = undefined
      })
  }

  const installPackages = async (): Promise<DesktopStatus> => {
    const commands = await installCommands(system, osRelease(system))
    if (commands === undefined)
      throw new HttpFailure(501, "Codevisor doesn't know how to install packages on this system")

    if (busy !== undefined) return status()

    busy = installing
    try {
      await requirePasswordlessSudo(installing)
    } catch (cause) {
      busy = undefined
      throw cause
    }
    installInTheBackground(commands)
    return status()
  }

  const replaceOld = async (): Promise<DesktopStatus> => {
    const old = oldDesktop(system)
    if (old === undefined) return status()

    await requirePasswordlessSudo("Removing the older desktop")
    await asRoot("Removing the older desktop", old.removal)
    return status()
  }

  const layoutToUse = (): DesktopLayout => {
    const setup = setUp()
    const isOurs = setup.kind === "ready" && recordedService() !== undefined
    const recorded = isOurs ? setup.config : undefined
    const display = stillUsable(recorded?.display, recorded?.socket) ?? freeDisplay(system)
    if (display === undefined) throw new HttpFailure(500, "No X11 display number is free")

    return desktopLayout(system, display)
  }

  const stillUsable = (
    display: number | undefined,
    socket: string | undefined
  ): number | undefined => {
    if (display === undefined || socket === undefined) return undefined

    return displayIsOursOrFree(system, display, socket) ? display : undefined
  }

  const someoneElsesConfig = (runs: DesktopService, other: DesktopService): boolean =>
    setUp().kind === "ready" &&
    recordedService() === undefined &&
    !runs.isSetUp() &&
    !other.isSetUp()

  const keptSettings = (): { name: string; defaultSize: string } => {
    const setup = setUp()
    const config = setup.kind === "ready" ? setup.config : undefined
    const hasSize = config?.defaultWidth !== undefined && config.defaultHeight !== undefined
    return {
      name: config?.name ?? "Desktop",
      defaultSize: hasSize ? `${config.defaultWidth}x${config.defaultHeight}` : DESKTOP_SIZE
    }
  }

  const writeConfig = (layout: DesktopLayout, runs: DesktopService): void => {
    const { name, defaultSize } = keptSettings()
    const vnc = {
      socket: layout.socket,
      display: layout.display,
      xauthority: layout.xauthority,
      name,
      desktop: "xfce",
      defaultSize
    }
    system.writeText(configPath, `${JSON.stringify({ vnc, service: runs.kind }, null, 2)}\n`)
  }

  const staysUp = async (layout: DesktopLayout): Promise<boolean> => {
    let steady = 0
    for (let poll = 0; poll < startPolls && steady < steadyPolls; poll += 1) {
      steady = locate(layout.socket).problem === undefined ? steady + 1 : 0
      await system.sleep(startPollMs)
    }
    return steady >= steadyPolls
  }

  const start = async (asked: StartOptions): Promise<DesktopStatus> => {
    const missing = await missingPrograms(system)
    if (missing.length > 0)
      throw new HttpFailure(
        409,
        `The desktop can't start until these are installed: ${missing.join(", ")}`
      )

    const { current: runs, other } = await services()
    if (runs.belongsToAnother()) throw new HttpFailure(409, anotherServers)
    if (sharedBy(runs).state === "running" && runs.isSetUp()) {
      await runs.refresh()
      return status()
    }
    if (someoneElsesConfig(runs, other) && asked.replaceUnmanaged !== true)
      throw new HttpFailure(409, unmanaged)

    const layout = layoutToUse()
    await other.stop()
    writeConfig(layout, runs)
    await runs.start()
    const up = await staysUp(layout)
    changed()
    if (!up) throw new HttpFailure(500, `The desktop didn't start.\n${await runs.recentLog()}`)

    return status()
  }

  const remove = async (): Promise<DesktopStatus> => {
    system.remove(configPath)
    changed()
    const { current, other } = await services()
    await current.stop()
    await other.stop()
    return status()
  }

  const resume = async (): Promise<void> => {
    const runs = await service()
    await runs.refresh()
    if (recordedService() !== "process" || setUp().kind !== "ready") return
    if (runs.kind === "process" && !runs.isSetUp()) await runs.start()
  }

  return {
    status,
    installPackages,
    replaceOld: () => unlessBusy(replaceOld),
    start: (asked = {}) => unlessBusy(() => start(asked)),
    remove: () => unlessBusy(remove),
    resume: () => oneAtATime(resume)
  }
}
