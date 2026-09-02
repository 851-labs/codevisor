import type { OpenCodeAuthMethod, OpenCodeAuthPrompt } from "@codevisor/api"
import { randomBytes } from "node:crypto"
import { readFile } from "node:fs/promises"
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process"

/// The control-plane side of OpenCode authentication: a short-lived
/// `opencode serve` per operation, its authenticated HTTP requests, and the
/// translation of OpenCode's provider/method/prompt shapes onto the API.

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

export interface ProviderListResponse {
  readonly all?: ReadonlyArray<ProviderInfo>
}

export interface UpstreamPrompt {
  readonly type?: string
  readonly key?: string
  readonly message?: string
  readonly placeholder?: string
  readonly options?: ReadonlyArray<{
    readonly value?: string
    readonly label?: string
    readonly hint?: string
  }>
  readonly when?: { readonly key?: string; readonly op?: string; readonly value?: string }
}

export interface UpstreamMethod {
  readonly type?: string
  readonly label?: string
  readonly prompts?: ReadonlyArray<UpstreamPrompt>
}

export interface AuthorizationResponse {
  readonly url?: string
  readonly method?: string
  readonly instructions?: string
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
        // Provider discovery and credential exchange don't need OpenCode's session data.
        // Keeping this control-plane server in memory prevents it from racing a chat
        // process (or another auth request) through opencode.db startup migrations.
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

export const request = async <A>(
  server: OpenCodeServer,
  path: string,
  init: RequestInit = {}
): Promise<A> => {
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
      const parsed = JSON.parse(text) as { data?: { message?: string }; message?: string }
      detail = parsed.data?.message ?? parsed.message ?? text
    } catch {
      // Preserve the response body when OpenCode did not return JSON.
    }
    throw new Error(detail.trim() || `OpenCode authentication request failed (${response.status})`)
  }
  return (text.length === 0 ? undefined : JSON.parse(text)) as A
}

export const workspaceQuery = (profile: OpenCodeProfile): string =>
  `?directory=${encodeURIComponent(profile.cwd)}`

export const promptValue = (prompt: UpstreamPrompt): OpenCodeAuthPrompt | undefined => {
  if (
    (prompt.type !== "text" && prompt.type !== "select") ||
    prompt.key === undefined ||
    prompt.message === undefined
  ) {
    return undefined
  }
  const when: { key: string; op: "eq" | "neq"; value: string } | undefined =
    prompt.when?.key !== undefined &&
    (prompt.when.op === "eq" || prompt.when.op === "neq") &&
    prompt.when.value !== undefined
      ? { key: prompt.when.key, op: prompt.when.op, value: prompt.when.value }
      : undefined
  return {
    type: prompt.type,
    key: prompt.key,
    message: prompt.message,
    options:
      prompt.type === "select"
        ? (prompt.options ?? []).flatMap((option) =>
            option.value === undefined || option.label === undefined
              ? []
              : [
                  {
                    value: option.value,
                    label: option.label,
                    ...(option.hint === undefined ? {} : { hint: option.hint })
                  }
                ]
          )
        : [],
    ...(prompt.placeholder === undefined ? {} : { placeholder: prompt.placeholder }),
    ...(when === undefined ? {} : { when })
  }
}

export const methodValues = (
  methods: ReadonlyArray<UpstreamMethod> | undefined
): OpenCodeAuthMethod[] => {
  const source: ReadonlyArray<UpstreamMethod> =
    methods === undefined || methods.length === 0 ? [{ type: "api", label: "API key" }] : methods
  return source.flatMap((method, index) => {
    if (method.type !== "api" && method.type !== "oauth") return []
    return [
      {
        id: String(index),
        type: method.type,
        label: method.type === "api" ? "API key" : (method.label ?? "Provider account"),
        prompts: (method.prompts ?? []).flatMap((prompt) => {
          const value = promptValue(prompt)
          return value === undefined ? [] : [value]
        })
      }
    ]
  })
}

export const credentialTypes = async (path: string): Promise<Record<string, CredentialType>> => {
  try {
    const raw = JSON.parse(await readFile(path, "utf8")) as Record<string, { type?: string }>
    return Object.fromEntries(
      Object.entries(raw).flatMap(([providerId, credential]) =>
        credential.type === "api" || credential.type === "oauth" || credential.type === "wellknown"
          ? [[providerId.replace(/\/+$/, ""), credential.type]]
          : []
      )
    )
  } catch (cause) {
    if ((cause as NodeJS.ErrnoException).code === "ENOENT") return {}
    throw cause
  }
}
