import { join } from "node:path"

import type { DesktopCommand, DesktopState, DesktopStatus } from "@codevisor/api"

import { type PrivateSocket, privateSocket } from "../routes/private-socket.js"
import {
  type DesktopSetup,
  desktopSetup,
  SCREEN_SHARING_CONFIG_FILE
} from "../routes/screen-sharing-vnc.js"
import { HttpFailure } from "../server-context.js"
import { DESKTOP_SIZE, desktopLayout, type DesktopLayout, freeDisplay } from "./desktop-layout.js"
import {
  installCommands,
  missingPrograms,
  osRelease,
  runAsRoot,
  sudoKind
} from "./desktop-packages.js"
import { desktopService, type DesktopService, type RunnerCommand } from "./desktop-service.js"
import type { DesktopSystem } from "./desktop-system.js"
import { oldDesktop } from "./old-desktop.js"

export interface DesktopManager {
  readonly status: () => Promise<DesktopStatus>
  readonly installPackages: () => Promise<DesktopStatus>
  readonly replaceOld: () => Promise<DesktopStatus>
  readonly start: () => Promise<DesktopStatus>
  readonly remove: () => Promise<DesktopStatus>
  readonly resume: () => Promise<void>
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

export const makeDesktopManager = (options: DesktopManagerOptions): DesktopManager => {
  const { system, dataDir, changed } = options
  const locate = options.locate ?? privateSocket
  const configPath = join(dataDir, SCREEN_SHARING_CONFIG_FILE)
  const service = (): Promise<DesktopService> => desktopService(system, options.runner, options)
  let busy: string | undefined
  let failure: string | undefined
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
    const processIsGone = recordedService() === "process" && !runs.isSetUp()
    if (live.state !== "running" || !processIsGone) return live

    return { ...live, state: "stopped", problem: "the desktop's process isn't running" }
  }

  const status = async (): Promise<DesktopStatus> => {
    const release = osRelease(system)
    const runs = await service()
    const install = await installCommands(system, release)
    const old = oldDesktop(system)
    const startsAtBoot = await runs.startsAtBoot()
    const needsLinger = runs.kind === "systemd-user" && !startsAtBoot
    return {
      ...sharedBy(runs),
      ...(busy === undefined ? {} : { busy }),
      ...(failure === undefined ? {} : { failure }),
      account: system.account,
      system: release.name,
      missing: await missingPrograms(system),
      ...(install === undefined ? {} : { install }),
      sudo: await sudoKind(system),
      ...(old === undefined ? {} : { oldDesktop: old }),
      startsAtBoot,
      ...(needsLinger ? { startAtBootHint: `sudo loginctl enable-linger ${system.account}` } : {}),
      logHint: runs.logHint
    }
  }

  const requirePasswordlessSudo = async (what: string): Promise<void> => {
    if ((await sudoKind(system)) !== "passwordless")
      throw new HttpFailure(403, `${what} needs an administrator on this machine`)
  }

  const asRoot = async (what: string, commands: ReadonlyArray<DesktopCommand>): Promise<void> => {
    const ran = await runAsRoot(system, commands)
    if (!ran.ok) throw new HttpFailure(502, `${what} failed:\n${ran.output}`)
  }

  const installInTheBackground = (commands: ReadonlyArray<DesktopCommand>): void => {
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

    await requirePasswordlessSudo(installing)
    if (busy === undefined) installInTheBackground(commands)
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
    const display = (isOurs ? setup.config.display : undefined) ?? freeDisplay(system)
    if (display === undefined) throw new HttpFailure(500, "No X11 display number is free")

    return desktopLayout(system, display)
  }

  const writeConfig = (layout: DesktopLayout, runs: DesktopService): void =>
    system.writeText(
      configPath,
      `${JSON.stringify(
        {
          vnc: {
            socket: layout.socket,
            display: layout.display,
            xauthority: layout.xauthority,
            name: "Desktop",
            desktop: "xfce",
            defaultSize: DESKTOP_SIZE
          },
          service: runs.kind
        },
        null,
        2
      )}\n`
    )

  const staysUp = async (layout: DesktopLayout): Promise<boolean> => {
    let steady = 0
    for (let poll = 0; poll < startPolls && steady < steadyPolls; poll += 1) {
      steady = locate(layout.socket).problem === undefined ? steady + 1 : 0
      await system.sleep(startPollMs)
    }
    return steady >= steadyPolls
  }

  const start = async (): Promise<DesktopStatus> => {
    const missing = await missingPrograms(system)
    if (missing.length > 0)
      throw new HttpFailure(
        409,
        `The desktop can't start until these are installed: ${missing.join(", ")}`
      )

    const runs = await service()
    if (sharedBy(runs).state === "running" && runs.isSetUp()) return status()

    const layout = layoutToUse()
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
    await (await service()).stop()
    return status()
  }

  const resume = async (): Promise<void> => {
    if (recordedService() !== "process") return

    const runs = await service()
    if (runs.kind === "process" && !runs.isSetUp()) await runs.start()
  }

  return {
    status,
    installPackages,
    replaceOld: () => unlessBusy(replaceOld),
    start: () => unlessBusy(start),
    remove: () => unlessBusy(remove),
    resume
  }
}
