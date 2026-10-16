import { execFile, spawn } from "node:child_process"
import { join } from "node:path"
import { promisify } from "node:util"

import type { HarnessInstallMethodSpec } from "@codevisor/agent-runtime"
import { Effect } from "effect"

import type { LifecycleProcess } from "./harness-lifecycle-types.js"

const execFileAsync = promisify(execFile)

export const run = <A>(effect: Effect.Effect<A, unknown>): Promise<A> => Effect.runPromise(effect)

export const appBundlePath = (binaryPath: string): string | undefined => {
  const index = binaryPath.indexOf(".app/")
  return index === -1 ? undefined : binaryPath.slice(0, index + 4)
}

export const METHOD_PREFERENCE: ReadonlyArray<HarnessInstallMethodSpec["kind"]> = [
  "brew",
  "curl",
  "npm",
  "uv"
]

export const installCommand = (spec: HarnessInstallMethodSpec): string => {
  switch (spec.kind) {
    case "brew":
      return `brew install ${spec.cask === true ? "--cask " : ""}${spec.formula ?? ""}`.trim()
    case "npm":
      return `npm install -g ${spec.ignoreScripts === true ? "--ignore-scripts " : ""}${[spec.packageName, ...(spec.additionalPackages ?? [])].filter(Boolean).join(" ")}`.trim()
    case "uv":
      return `uv tool install ${spec.packageName ?? ""}${spec.python === undefined ? "" : ` --python ${spec.python}`}`.trim()
    default:
      return spec.command ?? ""
  }
}

export const upgradeCommand = (spec: HarnessInstallMethodSpec): string => {
  switch (spec.kind) {
    case "brew":
      return `brew upgrade ${spec.cask === true ? "--cask " : ""}${spec.formula ?? ""}`.trim()
    case "npm":
      return `npm install -g ${spec.ignoreScripts === true ? "--ignore-scripts " : ""}${[
        spec.packageName,
        ...(spec.additionalPackages ?? [])
      ]
        .filter(Boolean)
        .map((name) => `${name}@latest`)
        .join(" ")}`.trim()
    case "uv":
      return `uv tool upgrade ${spec.packageName ?? ""}`.trim()
    default:
      return spec.command ?? ""
  }
}

export const defaultSpawnShell = (command: string, env: NodeJS.ProcessEnv): LifecycleProcess => {
  const shell = env.SHELL !== undefined && env.SHELL !== "" ? env.SHELL : "/bin/sh"
  const child = spawn(shell, ["-lc", command], {
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
      } catch {}
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

export const sparkleFeedUrl = (arch: string, check: SparkleCheck): string =>
  process.env.CODEVISOR_CODEX_APPCAST_URL ??
  (arch === "x64" && check.appcastUrlX64 !== undefined ? check.appcastUrlX64 : check.appcastUrl)
