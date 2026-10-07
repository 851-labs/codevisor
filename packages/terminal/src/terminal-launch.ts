import type { TerminalCreateRequest } from "@codevisor/api"

import { BUNDLED_GHOSTTY_RESOURCES_DIRECTORY, withShellIntegration } from "./shell-integration.js"
import {
  BUNDLED_GHOSTTY_TERMINFO_DIRECTORY,
  GHOSTTY_TERM,
  resolveDefaultShell,
  resolveTerminalName,
  withDefaultLocale
} from "./shell.js"
import type { TerminalManagerConfig, TerminalSpawnRequest } from "./types.js"

interface LaunchDefaults {
  readonly env: NodeJS.ProcessEnv
  readonly terminfoDirectory: string
  readonly defaultShell: string
  readonly platform: NodeJS.Platform
  readonly terminalName: string
  readonly ghosttyResources: string
}

const captureDefaults = (config: TerminalManagerConfig): LaunchDefaults => {
  const env = config.env ?? process.env
  const terminfoDirectory = config.terminfoDirectory ?? BUNDLED_GHOSTTY_TERMINFO_DIRECTORY
  const defaultShell = resolveDefaultShell(config, env)
  const platform = config.platform ?? process.platform
  const terminalName = resolveTerminalName(platform)
  const ghosttyResources = config.ghosttyResourcesDirectory ?? BUNDLED_GHOSTTY_RESOURCES_DIRECTORY
  return { env, terminfoDirectory, defaultShell, platform, terminalName, ghosttyResources }
}

const prepareEnvironment = (
  defaults: LaunchDefaults,
  envOverrides: NodeJS.ProcessEnv | undefined
): NodeJS.ProcessEnv => {
  // Match Ghostty's launch environment on macOS. Linux uses the
  // broadly recognized xterm-256color name so stock distro profiles
  // enable colors without requiring Ghostty-specific TERM handling.
  const env: NodeJS.ProcessEnv = {
    ...defaults.env,
    ...envOverrides,
    COLORTERM: "truecolor",
    TERM: defaults.terminalName,
    TERM_PROGRAM: "ghostty"
  }
  if (defaults.terminalName === GHOSTTY_TERM) {
    env.TERMINFO = defaults.terminfoDirectory
  } else {
    // An inherited Ghostty-only TERMINFO masks the host's standard
    // xterm-256color database for shells such as Zsh.
    delete env.TERMINFO
  }
  return env
}

const prepareLaunch = (
  defaults: LaunchDefaults,
  request: TerminalCreateRequest,
  envOverrides: NodeJS.ProcessEnv | undefined
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
  return { ...request, shell, ...launch }
}

/// Captures manager launch defaults once while retaining the environment reference.
export const makeTerminalLaunch = (config: TerminalManagerConfig) => {
  const defaults = captureDefaults(config)
  return (request: TerminalCreateRequest, envOverrides?: NodeJS.ProcessEnv): TerminalSpawnRequest =>
    prepareLaunch(defaults, request, envOverrides)
}
