import { execFile } from "node:child_process"
import { accessSync, constants, readdirSync } from "node:fs"
import { homedir as osHomedir, userInfo } from "node:os"

export interface ShellEnvOptions {
  readonly base?: NodeJS.ProcessEnv
  readonly platform?: NodeJS.Platform
  readonly homedir?: string
  readonly runShell?: (
    shell: string,
    args: ReadonlyArray<string>,
    timeoutMs: number,
    env: NodeJS.ProcessEnv
  ) => Promise<string>
  readonly timeoutMs?: number
  readonly userShell?: () => string | undefined
  readonly executableExists?: (path: string) => boolean
  readonly listDirectory?: (path: string) => ReadonlyArray<string>
}

export const fallbackPathDirectories = (home: string): ReadonlyArray<string> => [
  `${home}/.local/bin`,
  "/opt/homebrew/bin",
  "/usr/local/bin",
  "/usr/local/sbin",
  "/usr/bin",
  "/bin",
  "/usr/sbin",
  "/sbin",
  "/snap/bin",
  `${home}/.volta/bin`,
  `${home}/.asdf/shims`,
  `${home}/.bun/bin`,
  `${home}/.cargo/bin`,
  `${home}/.deno/bin`,
  `${home}/.npm-global/bin`,
  `${home}/.nix-profile/bin`,
  "/nix/var/nix/profiles/default/bin"
]

const listDirectoryOrEmpty = (path: string): ReadonlyArray<string> => {
  try {
    return readdirSync(path)
  } catch {
    return []
  }
}

export const nvmBinDirectories = (
  home: string,
  listDirectory: (path: string) => ReadonlyArray<string> = listDirectoryOrEmpty
): ReadonlyArray<string> => {
  const root = `${home}/.nvm/versions/node`
  const versions = listDirectory(root).flatMap((name) => {
    const match = name.match(/^v(\d+)\.(\d+)\.(\d+)$/)
    if (match === null) return []
    return [{ name, parts: [Number(match[1]), Number(match[2]), Number(match[3])] as const }]
  })
  versions.sort(
    (a, b) => b.parts[0] - a.parts[0] || b.parts[1] - a.parts[1] || b.parts[2] - a.parts[2]
  )
  const newest = versions[0]
  return newest === undefined ? [] : [`${root}/${newest.name}/bin`]
}

const executableExistsSync = (path: string): boolean => {
  try {
    accessSync(path, constants.X_OK)
    return true
  } catch {
    return false
  }
}

/* v8 ignore start */
const userShellFromPasswd = (): string | undefined => {
  try {
    const shell = userInfo().shell
    return shell === null || shell === "" ? undefined : shell
  } catch {
    return undefined
  }
}
/* v8 ignore stop */

export const runShellCommand = (
  shell: string,
  args: ReadonlyArray<string>,
  timeoutMs: number,
  env: NodeJS.ProcessEnv = process.env
): Promise<string> =>
  new Promise<string>((resolve, reject) => {
    execFile(shell, [...args], { env, timeout: timeoutMs }, (error, stdout) => {
      if (error === null) {
        resolve(stdout)
      } else {
        reject(error)
      }
    })
  })

const pathFromEnvOutput = (output: string): string | undefined => {
  let path: string | undefined
  for (const line of output.split("\n")) {
    if (line.startsWith("PATH=")) {
      path = line.slice("PATH=".length)
    }
  }
  return path
}

const splitPath = (path: string | undefined): ReadonlyArray<string> =>
  (path ?? "").split(":").filter((directory) => directory.length > 0)

const mergedPath = (groups: ReadonlyArray<ReadonlyArray<string>>): string => {
  const directories: string[] = []
  for (const group of groups) {
    for (const directory of group) {
      if (!directories.includes(directory)) {
        directories.push(directory)
      }
    }
  }
  return directories.join(":")
}

const chooseShell = (
  base: NodeJS.ProcessEnv,
  platform: NodeJS.Platform,
  userShell: () => string | undefined,
  executableExists: (path: string) => boolean
): string | undefined => {
  const platformDefault = platform === "darwin" ? "/bin/zsh" : "/bin/bash"
  const candidates = [base.SHELL, userShell(), platformDefault, "/bin/sh"]
  for (const candidate of candidates) {
    if (candidate !== undefined && candidate !== "" && executableExists(candidate)) {
      return candidate
    }
  }
  return undefined
}

export const resolveShellEnv = async (
  options: ShellEnvOptions = {}
): Promise<NodeJS.ProcessEnv> => {
  const base = options.base ?? process.env
  const platform = options.platform ?? process.platform
  if (platform === "win32") {
    return base
  }
  const home = base.HOME || options.homedir || osHomedir() || userInfo().homedir
  const env = { ...base, HOME: home }
  const runShell = options.runShell ?? runShellCommand
  const timeoutMs = options.timeoutMs ?? 5000
  const shell = chooseShell(
    base,
    platform,
    options.userShell ?? userShellFromPasswd,
    options.executableExists ?? executableExistsSync
  )
  let probed: ReadonlyArray<string> = []
  if (shell !== undefined) {
    try {
      const output = await runShell(shell, ["-ilc", "/usr/bin/env"], timeoutMs, env)
      probed = splitPath(pathFromEnvOutput(output))
    } catch {}
  }
  return {
    ...env,
    PATH: mergedPath([
      probed,
      splitPath(base.PATH),
      fallbackPathDirectories(home),
      nvmBinDirectories(home, options.listDirectory)
    ])
  }
}

export const makeShellEnvCache = (resolve: () => Promise<NodeJS.ProcessEnv>) => {
  let latest: Promise<NodeJS.ProcessEnv> | undefined
  const refresh = () => (latest = resolve())
  return { refresh, current: () => latest ?? refresh() }
}
