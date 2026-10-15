import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process"
import { randomBytes } from "node:crypto"
import { readFile } from "node:fs/promises"

import { errnoCode, optionalString, parseJsonRecord, recordOrEmpty } from "./json-values.js"

export interface OpenCodeProfile {
  readonly command: string
  readonly cwd: string
  readonly env: NodeJS.ProcessEnv
  readonly authPath: string
}

export interface OpenCodeServer {
  readonly url: string
  readonly password: string
  readonly child: ChildProcessWithoutNullStreams
  readonly stop: () => Promise<void>
}

export interface ProviderInfo {
  readonly id: string
  readonly name: string
}

export interface UpstreamPrompt {
  readonly type?: string | undefined
  readonly key?: string | undefined
  readonly message?: string | undefined
  readonly placeholder?: string | undefined
  readonly options: ReadonlyArray<{
    readonly value?: string | undefined
    readonly label?: string | undefined
    readonly hint?: string | undefined
  }>
  readonly when: {
    readonly key?: string | undefined
    readonly op?: string | undefined
    readonly value?: string | undefined
  }
}

export interface UpstreamMethod {
  readonly type?: string | undefined
  readonly label?: string | undefined
  readonly prompts?: ReadonlyArray<UpstreamPrompt>
}

export interface AuthorizationResponse {
  readonly url?: string | undefined
  readonly method?: string | undefined
  readonly instructions?: string | undefined
}

export type CredentialType = "api" | "oauth" | "wellknown"

export const failureMessage = (cause: unknown): string =>
  cause instanceof Error ? cause.message : String(cause)

export const stopChild = (child: ChildProcessWithoutNullStreams): Promise<void> => {
  if (child.exitCode !== null) return Promise.resolve()
  return new Promise((resolve) => {
    const done = (): void => {
      clearTimeout(timer)
      resolve()
    }
    child.once("exit", done)
    if (!child.killed) child.kill("SIGTERM")
    const timer = setTimeout(() => {
      if (child.exitCode === null) child.kill("SIGKILL")
    }, 1_000)
    timer.unref()
  })
}

export const startServer = async (profile: OpenCodeProfile): Promise<OpenCodeServer> => {
  const password = randomBytes(24).toString("base64url")
  const child = spawn(
    profile.command,
    ["serve", "--hostname", "127.0.0.1", "--port", "0", "--no-mdns"],
    {
      cwd: profile.cwd,
      env: {
        ...profile.env,
        OPENCODE_DB: ":memory:",
        OPENCODE_SERVER_PASSWORD: password
      },
      stdio: ["pipe", "pipe", "pipe"]
    }
  )
  child.stdout.setEncoding("utf8")
  child.stderr.setEncoding("utf8")
  let output = ""
  let errorOutput = ""
  child.stderr.on("data", (chunk: string) => {
    if (errorOutput.length < 16_384) errorOutput += chunk
  })

  const url = await new Promise<string>((resolve, reject) => {
    const timeout = setTimeout(() => {
      cleanup()
      void stopChild(child)
      reject(new Error("OpenCode auth server did not start within 15 seconds"))
    }, 15_000)
    const cleanup = (): void => {
      clearTimeout(timeout)
      child.stdout.off("data", onData)
      child.off("error", onError)
      child.off("exit", onExit)
    }
    const onData = (chunk: string): void => {
      if (output.length < 16_384) output += chunk
      const match = output.match(/opencode server listening on (http:\/\/[^\s]+)/)
      if (match?.[1] === undefined) return
      cleanup()
      resolve(match[1])
    }
    const onError = (cause: Error): void => {
      cleanup()
      reject(cause)
    }
    const onExit = (code: number | null): void => {
      cleanup()
      reject(
        new Error(
          errorOutput.trim() ||
            `OpenCode auth server exited before startup (status ${code ?? "unknown"})`
        )
      )
    }
    child.stdout.on("data", onData)
    child.once("error", onError)
    child.once("exit", onExit)
  })
  child.stdout.on("data", () => undefined)
  child.on("error", () => undefined)

  let stopPromise: Promise<void> | undefined
  return {
    url,
    password,
    child,
    stop: () => {
      stopPromise ??= stopChild(child)
      return stopPromise
    }
  }
}

export const request = async (
  server: OpenCodeServer,
  path: string,
  init: RequestInit = {}
): Promise<unknown> => {
  const headers = new Headers(init.headers)
  headers.set(
    "authorization",
    `Basic ${Buffer.from(`opencode:${server.password}`).toString("base64")}`
  )
  if (init.body !== undefined) headers.set("content-type", "application/json")
  const response = await fetch(`${server.url}${path}`, { ...init, headers })
  const text = await response.text()
  if (!response.ok) {
    let detail = text
    try {
      const parsed = recordOrEmpty(JSON.parse(text))
      detail =
        optionalString(recordOrEmpty(parsed.data).message) ?? optionalString(parsed.message) ?? text
    } catch {}
    throw new Error(detail.trim() || `OpenCode authentication request failed (${response.status})`)
  }
  return text.length === 0 ? undefined : JSON.parse(text)
}

export const workspaceQuery = (profile: OpenCodeProfile): string =>
  `?directory=${encodeURIComponent(profile.cwd)}`

export const credentialTypes = async (path: string): Promise<Record<string, CredentialType>> => {
  try {
    const raw = parseJsonRecord(await readFile(path, "utf8"))
    return Object.fromEntries(
      Object.entries(raw).flatMap(([providerId, credential]) => {
        const type = recordOrEmpty(credential).type
        return type === "api" || type === "oauth" || type === "wellknown"
          ? [[providerId.replace(/\/+$/, ""), type]]
          : []
      })
    )
  } catch (cause) {
    if (errnoCode(cause) === "ENOENT") return {}
    throw cause
  }
}
