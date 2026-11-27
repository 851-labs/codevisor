import type { TerminalCreateRequest } from "@codevisor/api"
import { Effect } from "effect"

import { withoutInheritedResume, withProgramResume } from "./program-resume-shell.js"
import { BUNDLED_GHOSTTY_RESOURCES_DIRECTORY, withShellIntegration } from "./shell-integration.js"
import {
  BUNDLED_GHOSTTY_TERMINFO_DIRECTORY,
  GHOSTTY_TERM,
  resolveDefaultShell,
  resolveTerminalName,
  resolveUserId,
  withDefaultLocale
} from "./shell.js"
import type { TerminalManagerConfig, TerminalSpawner, TerminalSpawnRequest } from "./types.js"

interface LaunchDefaults {
  readonly env: NodeJS.ProcessEnv
  readonly defaultShell: string
  readonly platform: NodeJS.Platform
  readonly terminalName: string
  readonly ghosttyResources: string
  readonly userId: number | undefined
}

export type PrepareSpawn = (
  request: TerminalCreateRequest,
  envOverrides?: NodeJS.ProcessEnv,
  resumeFile?: string
) => TerminalSpawnRequest

const captureDefaults = (config: TerminalManagerConfig): LaunchDefaults => {
  const env = config.env ?? process.env
  const defaultShell = resolveDefaultShell(config, env)
  const platform = config.platform ?? process.platform
  const terminalName = resolveTerminalName(platform)
  const ghosttyResources = config.ghosttyResourcesDirectory ?? BUNDLED_GHOSTTY_RESOURCES_DIRECTORY
  const userId = resolveUserId(config)
  return { env, defaultShell, platform, terminalName, ghosttyResources, userId }
}

const prepareEnvironment = (
  defaults: LaunchDefaults,
  envOverrides: NodeJS.ProcessEnv | undefined
): NodeJS.ProcessEnv => {
  const env: NodeJS.ProcessEnv = {
    ...withoutInheritedResume(defaults.env),
    ...envOverrides,
    COLORTERM: "truecolor",
    TERM: defaults.terminalName,
    TERM_PROGRAM: "ghostty"
  }
  if (defaults.terminalName === GHOSTTY_TERM) {
    env.TERMINFO = BUNDLED_GHOSTTY_TERMINFO_DIRECTORY
  } else {
    delete env.TERMINFO
  }
  return env
}

const prepareLaunch = (
  defaults: LaunchDefaults,
  request: TerminalCreateRequest,
  envOverrides: NodeJS.ProcessEnv | undefined,
  resumeFile: string | undefined
): TerminalSpawnRequest => {
  const env = prepareEnvironment(defaults, envOverrides)
  const shell = request.shell ?? defaults.defaultShell
  const launch = withShellIntegration(
    shell,
    request.args ?? [],
    withDefaultLocale(env, defaults.platform),
    {
      resourcesDirectory: defaults.ghosttyResources,
      platform: defaults.platform
    }
  )
  const resumable = withProgramResume(shell, launch, {
    ghosttyResources: defaults.ghosttyResources,
    userId: defaults.userId,
    resumeFile
  })
  return { ...request, shell, ...resumable }
}

export const spawnerWithLaunchEnvironment = (
  spawner: TerminalSpawner,
  launchEnvironment: TerminalManagerConfig["launchEnvironment"]
): TerminalSpawner => {
  if (launchEnvironment === undefined) return spawner

  return {
    spawn: (request, handlers) =>
      Effect.suspend(() =>
        spawner.spawn({ ...request, env: launchEnvironment(request.env) }, handlers)
      )
  }
}

export const makeTerminalLaunch = (config: TerminalManagerConfig): PrepareSpawn => {
  const defaults = captureDefaults(config)
  return (request, envOverrides, resumeFile) =>
    prepareLaunch(defaults, request, envOverrides, resumeFile)
}
