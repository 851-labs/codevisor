import { accessSync, constants } from "node:fs"
import { userInfo } from "node:os"
import { fileURLToPath } from "node:url"

import type { TerminalManagerConfig } from "./types.js"

export const GHOSTTY_TERM = "xterm-ghostty"
export const PORTABLE_TERM = "xterm-256color"
export const BUNDLED_GHOSTTY_TERMINFO_DIRECTORY = fileURLToPath(
  new URL("../resources/terminfo", import.meta.url)
)

const executableExists = (path: string): boolean => {
  try {
    accessSync(path, constants.X_OK)
    return true
  } catch {
    return false
  }
}

/* v8 ignore start -- the failure branches depend on the host account database. */
const userShellFromPasswd = (): string | undefined => {
  try {
    const shell = userInfo().shell
    return shell === null || shell === "" ? undefined : shell
  } catch {
    return undefined
  }
}
/* v8 ignore stop */

export const resolveDefaultShell = (
  config: TerminalManagerConfig,
  env: NodeJS.ProcessEnv
): string => {
  if (config.defaultShell !== undefined) return config.defaultShell

  const canExecute = config.executableExists ?? executableExists
  const candidates = [env.SHELL, (config.userShell ?? userShellFromPasswd)()]
  for (const candidate of candidates) {
    if (candidate !== undefined && candidate !== "" && canExecute(candidate)) {
      return candidate
    }
  }
  return "/bin/sh"
}

export const resolveTerminalName = (platform: NodeJS.Platform): string =>
  platform === "darwin" ? GHOSTTY_TERM : PORTABLE_TERM

/// A shell started without any locale falls back to "C", where zsh shows
/// multibyte characters as raw bytes and TUIs mis-measure them. macOS apps
/// and launchd services often have none, so, like Ghostty, default macOS
/// shells to UTF-8 when nothing is set. Linux is left alone: its locales
/// vary by install, and a service there normally inherits one.
export const withDefaultLocale = (
  env: NodeJS.ProcessEnv,
  platform: NodeJS.Platform
): NodeJS.ProcessEnv =>
  platform !== "darwin" || env.LC_ALL || env.LC_CTYPE || env.LANG
    ? env
    : { ...env, LANG: "en_US.UTF-8" }
