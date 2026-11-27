import { readFileSync } from "node:fs"
import { join } from "node:path"

import {
  desktopSetup,
  recordedDesktopService,
  SCREEN_SHARING_CONFIG_FILE,
  x11Environment
} from "../routes/screen-sharing-vnc.js"

export type LaunchEnvironment = (env: NodeJS.ProcessEnv) => NodeJS.ProcessEnv

export interface DesktopEnvironmentOptions {
  readonly dataDir: string
  readonly platform?: NodeJS.Platform
}

export const desktopEnvironment = (options: DesktopEnvironmentOptions): LaunchEnvironment => {
  const platform = options.platform ?? process.platform
  if (platform !== "linux") return (env) => env

  return (env) => {
    if (alreadyHasADisplay(env)) return env

    const display = managedDesktopDisplay(options.dataDir)
    return display === undefined ? env : { ...env, ...display }
  }
}

const managedDesktopDisplay = (dataDir: string): Record<string, string> | undefined => {
  const text = configText(dataDir)
  if (text === undefined || recordedDesktopService(text) === undefined) return undefined

  const setup = desktopSetup(text)
  return setup.kind === "ready" ? x11Environment(setup.config) : undefined
}

const alreadyHasADisplay = (env: NodeJS.ProcessEnv): boolean =>
  env.DISPLAY !== undefined || env.WAYLAND_DISPLAY !== undefined

const configText = (dataDir: string): string | undefined => {
  try {
    return readFileSync(join(dataDir, SCREEN_SHARING_CONFIG_FILE), "utf8")
  } catch {
    return undefined
  }
}
