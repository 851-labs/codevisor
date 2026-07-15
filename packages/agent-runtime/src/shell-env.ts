import { execFile } from "node:child_process"
import { accessSync, constants, readdirSync } from "node:fs"
import { homedir as osHomedir, userInfo } from "node:os"

/// Login-shell PATH resolution.
///
/// GUI-launched (and service-launched) processes inherit a minimal PATH that
/// usually excludes Homebrew, nvm/volta/asdf, and per-user install dirs like
/// `~/.local/bin` (the Claude Code native installer default). Harness
/// detection scans PATH for agent CLIs, so the runtime recovers the user's
/// real PATH by asking their login shell — and merges well-known install
/// directories as a fallback when the probe fails.

export interface ShellEnvOptions {
  /// Environment to resolve from; defaults to `process.env`.
  readonly base?: NodeJS.ProcessEnv
  /// Platform override for tests; defaults to `process.platform`.
  readonly platform?: NodeJS.Platform
  /// Home directory used to expand fallback dirs; defaults to `os.homedir()`.
  readonly homedir?: string
  /// Shell runner returning stdout; defaults to an `execFile` wrapper.
  readonly runShell?: (
    shell: string,
    args: ReadonlyArray<string>,
    timeoutMs: number
  ) => Promise<string>
  /// Probe timeout; bounds pathological shell rc files. Default 5000ms.
  readonly timeoutMs?: number
  /// The user's passwd-database shell, tried when $SHELL is unset (systemd
  /// services and cron get no $SHELL). Defaults to `os.userInfo().shell`.
  readonly userShell?: () => string | undefined
  /// Whether an executable exists; guards probing a shell that isn't
  /// installed (minimal containers without bash). Defaults to `accessSync`.
  readonly executableExists?: (path: string) => boolean
  /// Directory listing used for the nvm probe; defaults to `readdirSync`.
  readonly listDirectory?: (path: string) => ReadonlyArray<string>
}

/// Well-known executable directories merged into every resolved PATH so
/// detection survives a failed shell probe or an unusual shell setup. Covers
/// the common install locations across macOS (Homebrew) and Linux (snap, nix,
/// npm prefix, deno) plus the version-manager shim dirs.
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

/// nvm keeps every Node version in its own bin dir and only rc files select
/// one, so a failed shell probe loses npm-installed CLIs entirely. Falling
/// back to the newest installed version matches what a fresh `nvm use node`
/// would pick.
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

/* v8 ignore start -- the empty/throwing branches depend on the host passwd database; both degrade to the platform default shell. */
const userShellFromPasswd = (): string | undefined => {
  try {
    const shell = userInfo().shell
    return shell === null || shell === "" ? undefined : shell
  } catch {
    return undefined
  }
}
/* v8 ignore stop */

/// Default shell runner: `execFile` with a hard timeout, resolving stdout.
export const runShellCommand = (
  shell: string,
  args: ReadonlyArray<string>,
  timeoutMs: number
): Promise<string> =>
  new Promise<string>((resolve, reject) => {
    execFile(shell, [...args], { timeout: timeoutMs }, (error, stdout) => {
      if (error === null) {
        resolve(stdout)
      } else {
        reject(error)
      }
    })
  })

/// Extracts the value of the last `PATH=` line from `env(1)` output. Using
/// `/usr/bin/env` instead of `echo $PATH` is fish-safe: fish prints `$PATH`
/// space-separated, but the exported variable is always colon-separated.
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

/// $SHELL when set (interactive logins), else the passwd-database shell
/// (systemd/cron), else the platform default — skipping anything that isn't
/// actually installed. `undefined` means no usable shell: skip the probe.
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

/// Returns `base` with PATH replaced by the merged login-shell PATH:
/// probed dirs first (user's own ordering wins), then the base PATH, then the
/// fallback dirs and the newest nvm bin. Any probe failure — spawn error,
/// timeout, empty output, no PATH line, no usable shell — degrades to base +
/// fallbacks. Windows is a passthrough.
export const resolveShellEnv = async (
  options: ShellEnvOptions = {}
): Promise<NodeJS.ProcessEnv> => {
  const base = options.base ?? process.env
  const platform = options.platform ?? process.platform
  if (platform === "win32") {
    return base
  }
  const home = options.homedir ?? osHomedir()
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
      // -i -l so the user's rc/profile files run — that's where PATH lives.
      const output = await runShell(shell, ["-ilc", "/usr/bin/env"], timeoutMs)
      probed = splitPath(pathFromEnvOutput(output))
    } catch {
      // Degrade to base + fallback directories below.
    }
  }
  return {
    ...base,
    PATH: mergedPath([
      probed,
      splitPath(base.PATH),
      fallbackPathDirectories(home),
      nvmBinDirectories(home, options.listDirectory)
    ])
  }
}
