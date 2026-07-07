import { execFile } from "node:child_process"
import { homedir as osHomedir } from "node:os"

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
}

/// Well-known executable directories merged into every resolved PATH so
/// detection survives a failed shell probe or an unusual shell setup.
export const fallbackPathDirectories = (home: string): ReadonlyArray<string> => [
  `${home}/.local/bin`,
  "/opt/homebrew/bin",
  "/usr/local/bin",
  "/usr/bin",
  "/bin",
  "/usr/sbin",
  "/sbin",
  `${home}/.volta/bin`,
  `${home}/.asdf/shims`,
  `${home}/.bun/bin`,
  `${home}/.cargo/bin`
]

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

/// Returns `base` with PATH replaced by the merged login-shell PATH:
/// probed dirs first (user's own ordering wins), then the base PATH, then the
/// fallback dirs. Any probe failure — spawn error, timeout, empty output, no
/// PATH line — degrades to base + fallbacks. Windows is a passthrough.
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
  const shell =
    base.SHELL !== undefined && base.SHELL !== ""
      ? base.SHELL
      : platform === "darwin"
        ? "/bin/zsh"
        : "/bin/bash"
  let probed: ReadonlyArray<string> = []
  try {
    // -i -l so the user's rc/profile files run — that's where PATH lives.
    const output = await runShell(shell, ["-ilc", "/usr/bin/env"], timeoutMs)
    probed = splitPath(pathFromEnvOutput(output))
  } catch {
    // Degrade to base + fallback directories below.
  }
  return {
    ...base,
    PATH: mergedPath([probed, splitPath(base.PATH), fallbackPathDirectories(home)])
  }
}
