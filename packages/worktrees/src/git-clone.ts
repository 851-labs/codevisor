import { spawn } from "node:child_process"

import { CloneError, classifyCloneFailure, type CloneFailureCode } from "./git-errors.js"

export type CloneStage = "counting" | "receiving" | "resolving" | "checkout"

export interface CloneProgress {
  readonly stage: CloneStage
  readonly percent?: number
  readonly completed?: number
  readonly total?: number
  readonly bytes?: number
  readonly bytesPerSecond?: number
}

const stagePrefixes: ReadonlyArray<readonly [string, CloneStage]> = [
  ["remote: enumerating", "counting"],
  ["remote: counting", "counting"],
  ["remote: compressing", "counting"],
  ["receiving objects", "receiving"],
  ["resolving deltas", "resolving"],
  ["updating files", "checkout"],
  ["checking out files", "checkout"]
]

const percentPattern = /:\s+(\d+)%\s+\((\d+)\/(\d+)\)(.*)$/
const transferPattern =
  /([\d.]+)\s+(bytes|KiB|MiB|GiB)(?:\s*\|\s*([\d.]+)\s+(bytes|KiB|MiB|GiB)\/s)?/

const unitBytes: Readonly<Record<string, number>> = {
  bytes: 1,
  KiB: 1024,
  MiB: 1024 ** 2,
  GiB: 1024 ** 3
}

const byteCount = (value: string, unit: string): number =>
  Math.round(Number(value) * unitBytes[unit]!)

export const parseCloneProgress = (line: string): CloneProgress | undefined => {
  const lower = line.trim().toLowerCase()
  const stage = stagePrefixes.find(([prefix]) => lower.startsWith(prefix))?.[1]
  if (stage === undefined) return undefined
  const match = percentPattern.exec(line)
  if (match === null) return { stage }
  const progress = {
    stage,
    percent: Math.min(100, Math.max(0, Number(match[1]))),
    completed: Number(match[2]),
    total: Number(match[3])
  }
  const transfer = transferPattern.exec(match[4]!)
  if (transfer === null) return progress
  const bytes = byteCount(transfer[1]!, transfer[2]!)
  return transfer[3] === undefined
    ? { ...progress, bytes }
    : { ...progress, bytes, bytesPerSecond: byteCount(transfer[3], transfer[4]!) }
}

const scpPattern = /^(?:[^@/\s]+@)?([^:/\s]+):(?!\/)(.+)$/
const sshPattern = /^ssh:\/\/(?:[^@/\s]+@)?([^:/\s]+)(:\d+)?\/(.+)$/
const httpsPattern = /^https?:\/\/(?:[^@/\s]+@)?([^:/\s]+)(:\d+)?\/(.+)$/

export const alternateCloneUrl = (rawUrl: string): string | undefined => {
  const url = rawUrl.trim()
  const ssh = sshPattern.exec(url)
  if (ssh !== null) return ssh[2] === undefined ? `https://${ssh[1]}/${ssh[3]}` : undefined
  const https = httpsPattern.exec(url)
  if (https !== null) return https[2] === undefined ? `git@${https[1]}:${https[3]}` : undefined
  if (/^[a-z][a-z0-9+.-]*:\/\//i.test(url)) return undefined
  const scp = scpPattern.exec(url)
  return scp === null ? undefined : `https://${scp[1]}/${scp[2]!.replace(/^\/+/, "")}`
}

export const cloneUrlHost = (rawUrl: string): string | undefined => {
  const url = rawUrl.trim()
  const match = sshPattern.exec(url) ?? httpsPattern.exec(url)
  if (match !== null) return match[1]!.toLowerCase()
  if (/^[a-z][a-z0-9+.-]*:\/\//i.test(url)) return undefined
  return scpPattern.exec(url)?.[1]?.toLowerCase()
}

export const cloneUrlScheme = (rawUrl: string): string => {
  const url = rawUrl.trim()
  const scheme = /^([a-z][a-z0-9+.-]*):\/\//i.exec(url)?.[1]
  if (scheme !== undefined) return scheme.toLowerCase()
  return scpPattern.test(url) ? "ssh" : "file"
}

export const nonInteractiveGitEnvironment = (env: NodeJS.ProcessEnv): NodeJS.ProcessEnv => ({
  ...env,
  GIT_TERMINAL_PROMPT: "0",
  GIT_ASKPASS: "true",
  SSH_ASKPASS: "true",
  GIT_SSH_COMMAND: env.GIT_SSH_COMMAND ?? "ssh -oBatchMode=yes -oConnectTimeout=15"
})

export interface RemoteProbeResult {
  readonly ok: boolean
  readonly code?: CloneFailureCode | undefined
  readonly message: string
}

const failurePrecedence: ReadonlyArray<CloneFailureCode> = [
  "cancelled",
  "repo_not_found",
  "auth_failed",
  "invalid_url",
  "network",
  "disk_full"
]

export const moreTellingFailure = (
  first: RemoteProbeResult,
  second: RemoteProbeResult
): RemoteProbeResult => (failureRank(second) < failureRank(first) ? second : first)

const failureRank = (result: RemoteProbeResult): number => {
  if (result.code === undefined) return failurePrecedence.length
  return failurePrecedence.indexOf(result.code)
}

export const probeRemote = (
  url: string,
  env: NodeJS.ProcessEnv = process.env,
  signal?: AbortSignal,
  timeoutMs = 30_000
): Promise<RemoteProbeResult> =>
  new Promise((resolve) => {
    const child = spawn("git", ["ls-remote", "-q", url, "HEAD"], {
      env: nonInteractiveGitEnvironment(env),
      stdio: ["ignore", "ignore", "pipe"],
      timeout: timeoutMs,
      killSignal: "SIGKILL",
      ...(signal === undefined ? {} : { signal })
    })
    let stderr = ""
    child.stderr.setEncoding("utf8")
    child.stderr.on("data", (chunk: string) => {
      stderr += chunk
    })
    child.once("error", () => undefined)
    child.once("close", (code) => {
      if (code === 0) {
        resolve({ ok: true, message: "" })
      } else if (signal?.aborted === true) {
        resolve({ ok: false, code: "cancelled", message: "Clone cancelled" })
      } else if (code === null) {
        resolve({ ok: false, code: "network", message: "Timed out reaching the repository" })
      } else {
        resolve({ ok: false, code: classifyCloneFailure(stderr), message: stderr.trim() })
      }
    })
  })

export const cloneCancelled = (): CloneError => new CloneError("Clone cancelled", "cancelled")
