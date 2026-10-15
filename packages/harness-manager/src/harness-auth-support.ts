import { execFile, spawn } from "node:child_process"
import { promisify } from "node:util"

import { Effect } from "effect"

import type { HarnessAuthExec } from "./harness-auth-types.js"
import {
  isRecord,
  optionalBoolean,
  optionalNumber,
  optionalString,
  recordOrEmpty
} from "./json-values.js"

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
  readonly loggedIn?: boolean | undefined
  readonly authMethod?: string | undefined
  readonly apiKeySource?: string | undefined
  readonly email?: string | undefined
  readonly orgId?: string | undefined
}

export const claudeAuthStatusFrom = (value: unknown): ClaudeAuthStatus => {
  const status = recordOrEmpty(value)
  return {
    loggedIn: optionalBoolean(status.loggedIn),
    authMethod: optionalString(status.authMethod),
    apiKeySource: optionalString(status.apiKeySource),
    email: optionalString(status.email),
    orgId: optionalString(status.orgId)
  }
}

export const parseClaudeAuthStatus = (output: string | undefined): ClaudeAuthStatus | undefined => {
  if (output === undefined || output.trim().length === 0) return undefined
  try {
    return claudeAuthStatusFrom(JSON.parse(output))
  } catch {
    return undefined
  }
}

export interface CursorAuthStatus {
  readonly isAuthenticated?: boolean | undefined
  readonly status?: string | undefined
  readonly userInfo?:
    | {
        readonly email?: string | undefined
        readonly userId?: number | undefined
        readonly firstName?: string | undefined
        readonly lastName?: string | undefined
        readonly teamId?: number | undefined
      }
    | undefined
}

const cursorAuthStatusFrom = (value: unknown): CursorAuthStatus => {
  const status = recordOrEmpty(value)
  const userInfo = isRecord(status.userInfo) ? status.userInfo : undefined
  return {
    isAuthenticated: optionalBoolean(status.isAuthenticated),
    status: optionalString(status.status),
    userInfo:
      userInfo === undefined
        ? undefined
        : {
            email: optionalString(userInfo.email),
            userId: optionalNumber(userInfo.userId),
            firstName: optionalString(userInfo.firstName),
            lastName: optionalString(userInfo.lastName),
            teamId: optionalNumber(userInfo.teamId)
          }
  }
}

export const parseCursorAuthStatus = (output: string | undefined): CursorAuthStatus | undefined => {
  if (output === undefined || output.trim().length === 0) return undefined
  try {
    return cursorAuthStatusFrom(JSON.parse(output))
  } catch {
    return undefined
  }
}

export interface ExecFailure {
  readonly stdout?: string | undefined
  readonly stderr?: string | undefined
  readonly code?: number | string | undefined
}

export const execFailure = (cause: unknown): ExecFailure => {
  const failure = recordOrEmpty(cause)
  return {
    stdout: optionalString(failure.stdout),
    stderr: optionalString(failure.stderr),
    code: optionalNumber(failure.code) ?? optionalString(failure.code)
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
  execFileAsync(command, [...args], options)

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
