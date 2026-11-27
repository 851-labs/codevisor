import { readFileSync } from "node:fs"
import { join } from "node:path"

import {
  desktopSetup,
  recordedDesktopService,
  SCREEN_SHARING_CONFIG_FILE
} from "../routes/screen-sharing-vnc.js"
import { desktopIsUp, type DesktopProcesses, type LocateSocket } from "./desktop-liveness.js"
import { type DesktopSystem, processAlive } from "./desktop-system.js"

export type LaunchEnvironment = (env: NodeJS.ProcessEnv) => NodeJS.ProcessEnv

export interface DesktopEnvironmentOptions {
  readonly dataDir: string
  readonly system?: DesktopProcesses & Pick<DesktopSystem, "platform">
  readonly locate?: LocateSocket
}

export const desktopEnvironment = (options: DesktopEnvironmentOptions): LaunchEnvironment => {
  const system = options.system ?? thisMachine
  if (system.platform !== "linux") return (env) => env

  const config = join(options.dataDir, SCREEN_SHARING_CONFIG_FILE)
  const ownDisplay = (): DesktopDisplay | undefined => runningDesktop(system, config, options)
  return (env) => {
    const from = whoseDisplay(env, config)
    if (from === "chosen") return env

    const own = ownDisplay()
    if (from === "another-server" && own === undefined) return env

    const bare = withoutCodevisorsDisplay(env)
    if (own === undefined || alreadyHasADisplay(bare)) return bare

    return { ...bare, ...own, [DISPLAY_MARK]: own.DISPLAY, [CONFIG_MARK]: config }
  }
}

interface DesktopDisplay {
  readonly DISPLAY: string
  readonly XAUTHORITY: string
}

type DisplaySource = "none" | "chosen" | "this-server" | "another-server"

const DISPLAY_MARK = "CODEVISOR_DESKTOP_DISPLAY"
const CONFIG_MARK = "CODEVISOR_DESKTOP_CONFIG"
const codevisorsOwn = new Set(["DISPLAY", "XAUTHORITY", DISPLAY_MARK, CONFIG_MARK])

const runningDesktop = (
  system: DesktopProcesses,
  configPath: string,
  { dataDir, locate }: DesktopEnvironmentOptions
): DesktopDisplay | undefined => {
  const text = system.readText(configPath)
  if (text === undefined || recordedDesktopService(text) === undefined) return undefined

  const setup = desktopSetup(text)
  if (setup.kind !== "ready") return undefined

  const { display, xauthority, socket } = setup.config
  if (display === undefined || xauthority === undefined) return undefined
  if (!desktopIsUp(system, { dataDir, socket }, locate)) return undefined

  return { DISPLAY: `:${display}`, XAUTHORITY: xauthority }
}

const whoseDisplay = (env: NodeJS.ProcessEnv, config: string): DisplaySource => {
  if (isCodevisorsDisplay(env))
    return env[CONFIG_MARK] === config ? "this-server" : "another-server"

  return alreadyHasADisplay(env) ? "chosen" : "none"
}

const isCodevisorsDisplay = (env: NodeJS.ProcessEnv): boolean =>
  env[DISPLAY_MARK] !== undefined && env.DISPLAY === env[DISPLAY_MARK]

const alreadyHasADisplay = (env: NodeJS.ProcessEnv): boolean =>
  env.DISPLAY !== undefined || env.WAYLAND_DISPLAY !== undefined

const withoutCodevisorsDisplay = (env: NodeJS.ProcessEnv): NodeJS.ProcessEnv => {
  if (!isCodevisorsDisplay(env)) return env

  return Object.fromEntries(Object.entries(env).filter(([name]) => !codevisorsOwn.has(name)))
}

const thisMachine: DesktopProcesses & Pick<DesktopSystem, "platform"> = {
  platform: process.platform,
  processAlive,
  readText: (path) => {
    try {
      return readFileSync(path, "utf8")
    } catch {
      return undefined
    }
  }
}
