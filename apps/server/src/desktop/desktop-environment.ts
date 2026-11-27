import { readFileSync } from "node:fs"
import { join } from "node:path"

import {
  desktopSetup,
  recordedDesktopService,
  SCREEN_SHARING_CONFIG_FILE
} from "../routes/screen-sharing-vnc.js"
import { sessionIsUp } from "./desktop-layout.js"
import { processAlive } from "./desktop-system.js"

export type LaunchEnvironment = (env: NodeJS.ProcessEnv) => NodeJS.ProcessEnv

export interface DesktopEnvironmentOptions {
  readonly dataDir: string
  readonly platform?: NodeJS.Platform
}

const DESKTOP_DISPLAY_MARK = "CODEVISOR_DESKTOP_DISPLAY"

export const desktopEnvironment = (options: DesktopEnvironmentOptions): LaunchEnvironment => {
  const platform = options.platform ?? process.platform
  if (platform !== "linux") return (env) => env

  const configPath = join(options.dataDir, SCREEN_SHARING_CONFIG_FILE)
  return (env) => {
    const chosen = withoutCodevisorsDisplay(env)
    if (alreadyHasADisplay(chosen)) return env

    const display = runningDesktopDisplay(configPath)
    if (display === undefined) return chosen

    return { ...chosen, ...display, [DESKTOP_DISPLAY_MARK]: display.DISPLAY }
  }
}

interface DesktopDisplay {
  readonly DISPLAY: string
  readonly XAUTHORITY: string
}

const runningDesktopDisplay = (configPath: string): DesktopDisplay | undefined => {
  const text = readText(configPath)
  if (text === undefined || recordedDesktopService(text) === undefined) return undefined

  const setup = desktopSetup(text)
  if (setup.kind !== "ready") return undefined

  const { display, xauthority, socket } = setup.config
  if (display === undefined || xauthority === undefined) return undefined
  if (!sessionIsUp({ readText, processAlive }, socket)) return undefined

  return { DISPLAY: `:${display}`, XAUTHORITY: xauthority }
}

const alreadyHasADisplay = (env: NodeJS.ProcessEnv): boolean =>
  env.DISPLAY !== undefined || env.WAYLAND_DISPLAY !== undefined

const withoutCodevisorsDisplay = (env: NodeJS.ProcessEnv): NodeJS.ProcessEnv => {
  if (!hasCodevisorsDisplay(env)) return env

  return Object.fromEntries(Object.entries(env).filter(([name]) => !codevisorsOwn.has(name)))
}

const hasCodevisorsDisplay = (env: NodeJS.ProcessEnv): boolean =>
  env[DESKTOP_DISPLAY_MARK] !== undefined && env.DISPLAY === env[DESKTOP_DISPLAY_MARK]

const codevisorsOwn = new Set(["DISPLAY", "XAUTHORITY", DESKTOP_DISPLAY_MARK])

const readText = (path: string): string | undefined => {
  try {
    return readFileSync(path, "utf8")
  } catch {
    return undefined
  }
}
