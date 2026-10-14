import { execFile, spawn } from "node:child_process"
import { promisify } from "node:util"

import { Effect } from "effect"

import type { HarnessAuthExec } from "./harness-auth-types.js"

const execFileAsync = promisify(execFile)

export const AUTH_CACHE_MS = 300_000
export const CODEX_PROBE_TIMEOUT_MS = 10_000
export const CURSOR_PROBE_TIMEOUT_MS = 10_000
export const CURSOR_LOGIN_URL_TIMEOUT_MS = 30_000
export const CLAUDE_AUTH_OVERRIDE_ENV_VARS = [
  "ANTHROPIC_API_KEY",
  "ANTHROPIC_AUTH_TOKEN",
  "CLAUDE_CODE_OAUTH_TOKEN",
  "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR",
  "CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR"
] as const

export interface ClaudeAuthStatus {
  readonly loggedIn?: boolean
  readonly authMethod?: string
  readonly apiKeySource?: string
  readonly email?: string
  readonly orgId?: string
}

export const parseClaudeAuthStatus = (output: string | undefined): ClaudeAuthStatus | undefined => {
  if (output === undefined || output.trim().length === 0) return undefined
  try {
    return JSON.parse(output) as ClaudeAuthStatus
  } catch {
    return undefined
  }
}

export interface CursorAuthStatus {
  readonly isAuthenticated?: boolean
  readonly status?: string
  readonly userInfo?: {
    readonly email?: string
    readonly userId?: number
    readonly firstName?: string
    readonly lastName?: string
    readonly teamId?: number
  }
}

export const parseCursorAuthStatus = (output: string | undefined): CursorAuthStatus | undefined => {
  if (output === undefined || output.trim().length === 0) return undefined
  try {
    return JSON.parse(output) as CursorAuthStatus
  } catch {
    return undefined
  }
}

export const parseCursorLoginUrl = (output: string): string | undefined =>
  /https:\/\/\S*cursor\.com\/\S+/.exec(output)?.[0]

export const withTimeout = async <A>(
  operation: Promise<A>,
  timeoutMs: number,
  message: string
): Promise<A> => {
  let timeout: ReturnType<typeof setTimeout> | undefined
  try {
    return await Promise.race([
      operation,
      new Promise<A>((_, reject) => {
        timeout = setTimeout(() => reject(new Error(message)), timeoutMs)
      })
    ])
  } finally {
    if (timeout !== undefined) clearTimeout(timeout)
  }
}

export const run = <A>(effect: Effect.Effect<A, unknown>): Promise<A> => Effect.runPromise(effect)

export const defaultExecFile: HarnessAuthExec = (command, args, options) =>
  execFileAsync(command, [...args], options) as Promise<{
    stdout: string
    stderr: string
  }>

export const runWithInput = async (
  command: string,
  args: ReadonlyArray<string>,
  input: string,
  env: NodeJS.ProcessEnv,
  cwd: string
): Promise<void> =>
  new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd, env, stdio: ["pipe", "ignore", "pipe"] })
    let stderr = ""
    child.stderr.setEncoding("utf8")
    child.stderr.on("data", (chunk: string) => {
      if (stderr.length < 16_384) stderr += chunk
    })
    child.once("error", reject)
    child.once("exit", (code) => {
      if (code === 0) resolve()
      else reject(new Error(stderr.trim() || `Authentication command exited with status ${code}`))
    })
    child.stdin.on("error", () => undefined)
    child.stdin.end(`${input}\n`)
  })
