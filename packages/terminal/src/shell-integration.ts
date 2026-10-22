import { existsSync } from "node:fs"
import { homedir } from "node:os"
import { basename, delimiter, join } from "node:path"
import { fileURLToPath } from "node:url"

export const BUNDLED_GHOSTTY_RESOURCES_DIRECTORY = fileURLToPath(
  new URL("../resources", import.meta.url)
)

const SHELL_FEATURES = "cursor:blink,title"

export interface ShellLaunch {
  readonly args: ReadonlyArray<string>
  readonly env: NodeJS.ProcessEnv
}

export interface ShellIntegrationOptions {
  readonly resourcesDirectory: string
  readonly platform: NodeJS.Platform
}

export const withShellIntegration = (
  shell: string,
  args: ReadonlyArray<string>,
  baseEnv: NodeJS.ProcessEnv,
  options: ShellIntegrationOptions
): ShellLaunch => {
  const resources = options.resourcesDirectory
  const env: NodeJS.ProcessEnv = {
    ...baseEnv,
    GHOSTTY_RESOURCES_DIR: resources,
    GHOSTTY_SHELL_FEATURES: SHELL_FEATURES
  }
  const integrated = (() => {
    switch (basename(shell)) {
      case "bash":
        if (options.platform === "darwin" && shell === "/bin/bash") return undefined
        return setupBash(args, env, resources)
      case "zsh":
        return setupZsh(args, env, resources)
      case "fish":
      case "elvish":
        return setupXdgDataDirs(env, resources) ? args : undefined
      case "nu":
        return setupNushell(args, env, resources)
      default:
        return undefined
    }
  })()
  return { args: integrated ?? args, env }
}

const setupBash = (
  args: ReadonlyArray<string>,
  env: NodeJS.ProcessEnv,
  resources: string
): ReadonlyArray<string> | undefined => {
  const script = join(resources, "shell-integration", "bash", "ghostty.bash")
  if (!existsSync(script)) return undefined
  const command = ["--posix"]
  let inject = "1"
  let rcfile: string | undefined
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index]!
    if (arg === "--posix") return undefined
    if (arg === "--norc" || arg === "--noprofile") {
      inject += ` ${arg}`
    } else if (arg === "--rcfile" || arg === "--init-file") {
      index += 1
      rcfile = args[index]
    } else if (arg.length > 1 && arg[0] === "-" && arg[1] !== "-") {
      if (arg.includes("c")) return undefined
      command.push(arg)
    } else if (arg === "-" || arg === "--") {
      command.push(...args.slice(index))
      break
    } else {
      command.push(arg)
    }
  }
  if (env.ENV !== undefined) env.GHOSTTY_BASH_ENV = env.ENV
  env.ENV = script
  env.GHOSTTY_BASH_INJECT = inject
  if (rcfile !== undefined) env.GHOSTTY_BASH_RCFILE = rcfile
  if (env.HISTFILE === undefined) {
    env.HISTFILE = join(env.HOME ?? homedir(), ".bash_history")
    env.GHOSTTY_BASH_UNEXPORT_HISTFILE = "1"
  }
  return command
}

const setupZsh = (
  args: ReadonlyArray<string>,
  env: NodeJS.ProcessEnv,
  resources: string
): ReadonlyArray<string> | undefined => {
  const directory = join(resources, "shell-integration", "zsh")
  if (!existsSync(directory)) return undefined
  if (env.ZDOTDIR !== undefined) env.GHOSTTY_ZSH_ZDOTDIR = env.ZDOTDIR
  env.ZDOTDIR = directory
  return args
}

const setupXdgDataDirs = (env: NodeJS.ProcessEnv, resources: string): boolean => {
  const directory = join(resources, "shell-integration")
  if (!existsSync(directory)) return false
  env.GHOSTTY_SHELL_INTEGRATION_XDG_DIR = directory
  const current = env.XDG_DATA_DIRS ?? "/usr/local/share:/usr/share"
  env.XDG_DATA_DIRS = current === "" ? directory : `${directory}${delimiter}${current}`
  return true
}

const setupNushell = (
  args: ReadonlyArray<string>,
  env: NodeJS.ProcessEnv,
  resources: string
): ReadonlyArray<string> | undefined => {
  if (!setupXdgDataDirs(env, resources)) return undefined
  const command = ["--execute", "use ghostty *"]
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index]!
    if (arg === "--command" || arg === "--lsp") return undefined
    if (arg.length > 1 && arg[0] === "-" && arg[1] !== "-") {
      if (arg.includes("c")) return undefined
      command.push(arg)
    } else if (arg === "-" || arg === "--") {
      command.push(...args.slice(index))
      break
    } else {
      command.push(arg)
    }
  }
  return command
}
