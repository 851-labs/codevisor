import { join } from "node:path"

import type { DesktopState, DesktopStatus } from "@codevisor/api"

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

const startPollMs = 250
const startPolls = 120

export const makeDesktopManager = (options: DesktopManagerOptions): DesktopManager => {
  const { system, dataDir, changed } = options
  const locate = options.locate ?? privateSocket
  const configPath = join(dataDir, SCREEN_SHARING_CONFIG_FILE)
  const service = (): Promise<DesktopService> => desktopService(system, options.runner, options)

  const setUp = (): DesktopSetup => {
    const text = system.readText(configPath)
    return text === undefined ? { kind: "absent" } : desktopSetup(text)
  }

  const shared = (): { state: DesktopState; display?: number; problem?: string } => {
    const setup = setUp()
    if (setup.kind === "outdated") return { state: "outdated" }
    if (setup.kind !== "ready") return { state: "none" }

    const socket = locate(setup.config.socket)
    const display = setup.config.display === undefined ? {} : { display: setup.config.display }
    if (socket.problem === undefined) return { state: "running", ...display }

    return { state: "stopped", ...display, problem: socket.detail }
  }

  const status = async (): Promise<DesktopStatus> => {
    const release = osRelease(system)
    const runs = await service()
    const install = await installCommands(system, release)
    const old = oldDesktop(system)
    const startsAtBoot = await runs.startsAtBoot()
    const needsLinger = runs.kind === "systemd-user" && !startsAtBoot
    return {
      ...shared(),
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

  const asRoot = async (
    what: string,
    commands: ReadonlyArray<ReadonlyArray<string>> | undefined
  ): Promise<void> => {
    if (commands === undefined) return
    if ((await sudoKind(system)) !== "passwordless")
      throw new HttpFailure(403, `${what} needs an administrator on this machine`)

    const ran = await runAsRoot(system, commands)
    if (!ran.ok) throw new HttpFailure(502, `${what} failed:\n${ran.output}`)
  }

  const installPackages = async (): Promise<DesktopStatus> => {
    const commands = await installCommands(system, osRelease(system))
    if (commands === undefined)
      throw new HttpFailure(501, "Codevisor doesn't know how to install packages on this system")

    await asRoot("Installing packages", commands)
    return status()
  }

  const replaceOld = async (): Promise<DesktopStatus> => {
    await asRoot("Removing the older desktop", oldDesktop(system)?.removal)
    return status()
  }

  const layoutToUse = (): DesktopLayout => {
    const setup = setUp()
    const kept = setup.kind === "ready" ? setup.config.display : undefined
    const display = kept ?? freeDisplay(system)
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

  const comesUp = async (layout: DesktopLayout): Promise<boolean> => {
    for (let poll = 0; poll < startPolls; poll += 1) {
      if (locate(layout.socket).problem === undefined) return true
      await system.sleep(startPollMs)
    }
    return false
  }

  const start = async (): Promise<DesktopStatus> => {
    const missing = await missingPrograms(system)
    if (missing.length > 0)
      throw new HttpFailure(
        409,
        `The desktop can't start until these are installed: ${missing.join(", ")}`
      )

    const runs = await service()
    if (shared().state === "running" && runs.isSetUp()) return status()

    const layout = layoutToUse()
    writeConfig(layout, runs)
    await runs.start()
    const up = await comesUp(layout)
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
    if (shared().state !== "stopped") return

    const runs = await service()
    if (runs.kind === "process" && !runs.isSetUp()) await runs.start()
  }

  return { status, installPackages, replaceOld, start, remove, resume }
}
