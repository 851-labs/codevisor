import type { HarnessInstallMethodSpec } from "@codevisor/agent-runtime"
import { execFile, spawn } from "node:child_process"
import { join } from "node:path"
import { promisify } from "node:util"
import { Effect } from "effect"
import type { LifecycleProcess } from "./harness-lifecycle-types.js"

const execFileAsync = promisify(execFile)

export const run = <A>(effect: Effect.Effect<A, unknown>): Promise<A> => Effect.runPromise(effect)

/// "/Applications/ChatGPT.app/Contents/Resources/codex" → the .app bundle.
export const appBundlePath = (binaryPath: string): string | undefined => {
  const index = binaryPath.indexOf(".app/")
  return index === -1 ? undefined : binaryPath.slice(0, index + 4)
}

/// Preference order among *available* methods.
export const METHOD_PREFERENCE: ReadonlyArray<HarnessInstallMethodSpec["kind"]> = [
  "brew",
  "curl",
  "npm"
]

export const installCommand = (spec: HarnessInstallMethodSpec): string => {
  switch (spec.kind) {
    case "brew":
      return `brew install ${spec.cask === true ? "--cask " : ""}${spec.formula ?? ""}`.trim()
    case "npm":
      return `npm install -g ${spec.packageName ?? ""}`.trim()
    case "curl":
      return spec.command ?? ""
  }
}

/// The reinstall-style update command for a method (brew upgrades in place,
/// npm reinstalls @latest, curl reruns the vendor script).
export const upgradeCommand = (spec: HarnessInstallMethodSpec): string => {
  switch (spec.kind) {
    case "brew":
      return `brew upgrade ${spec.cask === true ? "--cask " : ""}${spec.formula ?? ""}`.trim()
    case "npm":
      return `npm install -g ${spec.packageName ?? ""}@latest`.trim()
    case "curl":
      return spec.command ?? ""
  }
}

/// A method is runnable when its prerequisite tool exists on the PATH.
export const methodPrerequisite = (kind: HarnessInstallMethodSpec["kind"]): string =>
  kind === "brew" ? "brew" : kind === "npm" ? "npm" : "curl"

export const defaultSpawnShell = (command: string, env: NodeJS.ProcessEnv): LifecycleProcess => {
  const shell = env.SHELL !== undefined && env.SHELL !== "" ? env.SHELL : "/bin/sh"
  const child = spawn(shell, ["-lc", command], {
    // Its own group so a timeout kill takes worker descendants with it.
    detached: process.platform !== "win32",
    env,
    stdio: ["ignore", "pipe", "pipe"]
  })
  const outputListeners = new Set<(data: string) => void>()
  const exitListeners = new Set<(exitCode: number | undefined) => void>()
  const forward = (chunk: unknown): void => {
    const data = String(chunk)
    for (const listener of outputListeners) listener(data)
  }
  child.stdout.on("data", forward)
  child.stderr.on("data", forward)
  child.once("error", (cause) => {
    forward(`${cause.message}\n`)
    for (const listener of exitListeners) listener(undefined)
  })
  // `exit` can precede stdio closure when an updater hands work to a child
  // process. `close` does not fire until the inherited pipes are closed, so
  // it is the earliest safe point to begin target-version verification.
  child.once("close", (code) => {
    for (const listener of exitListeners) listener(code ?? undefined)
  })
  return {
    kill: () => {
      try {
        if (process.platform !== "win32" && child.pid !== undefined) {
          process.kill(-child.pid, "SIGKILL")
        } else {
          child.kill("SIGKILL")
        }
      } catch {
        // Already gone.
      }
    },
    onExit: (listener) => exitListeners.add(listener),
    onOutput: (listener) => outputListeners.add(listener)
  }
}

export const defaultReadBundleShortVersion = async (
  bundlePath: string
): Promise<string | undefined> => {
  try {
    const { stdout } = await execFileAsync(
      "plutil",
      ["-extract", "CFBundleShortVersionString", "raw", join(bundlePath, "Contents", "Info.plist")],
      { timeout: 5_000 }
    )
    const version = stdout.trim()
    return version.length > 0 ? version : undefined
  } catch {
    return undefined
  }
}

export interface SparkleCheck {
  readonly appcastUrl: string
  readonly appcastUrlX64?: string
}

/// The effective Sparkle feed for a check spec: arch-matched, with an env
/// override so end-to-end rehearsal can point at a fixture feed.
export const sparkleFeedUrl = (arch: string, check: SparkleCheck): string =>
  process.env.CODEVISOR_CODEX_APPCAST_URL ??
  (arch === "x64" && check.appcastUrlX64 !== undefined ? check.appcastUrlX64 : check.appcastUrl)
