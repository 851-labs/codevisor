import type {
  OpenCodeAuthFlow,
  OpenCodeAuthMethod,
  OpenCodeAuthPrompt,
  OpenCodeAuthProvider
} from "@codevisor/api"
import { randomBytes, randomUUID } from "node:crypto"
import { readFile } from "node:fs/promises"
import { homedir } from "node:os"
import { join } from "node:path"
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process"

interface OpenCodeProfile {
  readonly command: string
  readonly cwd: string
  readonly env: NodeJS.ProcessEnv
  readonly authPath: string
}

interface OpenCodeServer {
  readonly url: string
  readonly password: string
  readonly child: ChildProcessWithoutNullStreams
  readonly stop: () => Promise<void>
}

interface InternalFlow {
  value: OpenCodeAuthFlow
  readonly methodIndex: number
  readonly server: OpenCodeServer
  readonly workspaceQuery: string
  readonly release: () => void
  cancelled: boolean
}

interface ProviderInfo {
  readonly id: string
  readonly name: string
}

interface ProviderListResponse {
  readonly all?: ReadonlyArray<ProviderInfo>
}

interface UpstreamPrompt {
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

interface UpstreamMethod {
  readonly type?: string
  readonly label?: string
  readonly prompts?: ReadonlyArray<UpstreamPrompt>
}

interface AuthorizationResponse {
  readonly url?: string
  readonly method?: string
  readonly instructions?: string
}

type CredentialType = "api" | "oauth" | "wellknown"

export interface OpenCodeAuthManagerConfig {
  readonly profile: (accountId: string) => Promise<OpenCodeProfile>
}

export interface OpenCodeAuthManager {
  readonly providers: (accountId: string) => Promise<ReadonlyArray<OpenCodeAuthProvider>>
  readonly beginLogin: (
    accountId: string,
    providerId: string,
    methodId: string,
    inputs?: Readonly<Record<string, string>>,
    apiKey?: string
  ) => Promise<OpenCodeAuthFlow>
  readonly flow: (flowId: string) => OpenCodeAuthFlow
  readonly answer: (flowId: string, code: string) => Promise<OpenCodeAuthFlow>
  readonly cancel: (flowId: string) => void
  readonly logout: (accountId: string, providerId: string) => Promise<void>
}

const failureMessage = (cause: unknown): string =>
  cause instanceof Error ? cause.message : String(cause)

const stopChild = (child: ChildProcessWithoutNullStreams): Promise<void> => {
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

const startServer = async (profile: OpenCodeProfile): Promise<OpenCodeServer> => {
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

const request = async <A>(
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

const workspaceQuery = (profile: OpenCodeProfile): string =>
  `?directory=${encodeURIComponent(profile.cwd)}`

const promptValue = (prompt: UpstreamPrompt): OpenCodeAuthPrompt | undefined => {
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

const methodValues = (methods: ReadonlyArray<UpstreamMethod> | undefined): OpenCodeAuthMethod[] => {
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

const credentialTypes = async (path: string): Promise<Record<string, CredentialType>> => {
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

export const openCodeAuthPath = (env: NodeJS.ProcessEnv): string => {
  const home = env.HOME?.trim() || homedir()
  const dataHome = env.XDG_DATA_HOME?.trim() || join(home, ".local", "share")
  return join(dataHome, "opencode", "auth.json")
}

export const makeOpenCodeAuthManager = (config: OpenCodeAuthManagerConfig): OpenCodeAuthManager => {
  const flows = new Map<string, InternalFlow>()
  const accountLocks = new Map<string, Promise<void>>()

  const acquire = async (accountId: string): Promise<() => void> => {
    const previous = accountLocks.get(accountId) ?? Promise.resolve()
    let unlock = (): void => undefined
    const current = new Promise<void>((resolve) => {
      unlock = resolve
    })
    accountLocks.set(accountId, current)
    await previous
    let released = false
    return () => {
      if (released) return
      released = true
      unlock()
      if (accountLocks.get(accountId) === current) accountLocks.delete(accountId)
    }
  }

  const finish = (flow: InternalFlow, value: OpenCodeAuthFlow): void => {
    flow.value = value
    void flow.server
      .stop()
      .catch(() => undefined)
      .finally(flow.release)
  }

  const fail = (flow: InternalFlow, cause: unknown): void => {
    if (flow.cancelled) return
    finish(flow, {
      id: flow.value.id,
      accountId: flow.value.accountId,
      providerId: flow.value.providerId,
      state: "error",
      error: failureMessage(cause)
    })
  }

  const completeCallback = async (flow: InternalFlow, code?: string): Promise<void> => {
    try {
      await request<boolean>(
        flow.server,
        `/provider/${encodeURIComponent(flow.value.providerId)}/oauth/callback${flow.workspaceQuery}`,
        {
          method: "POST",
          body: JSON.stringify({
            method: flow.methodIndex,
            ...(code === undefined ? {} : { code })
          })
        }
      )
      if (flow.cancelled) return
      finish(flow, {
        id: flow.value.id,
        accountId: flow.value.accountId,
        providerId: flow.value.providerId,
        state: "complete"
      })
    } catch (cause) {
      fail(flow, cause)
    }
  }

  return {
    providers: async (accountId) => {
      const release = await acquire(accountId)
      let server: OpenCodeServer | undefined
      try {
        const profile = await config.profile(accountId)
        server = await startServer(profile)
        const query = workspaceQuery(profile)
        const [catalog, authMethods, credentials] = await Promise.all([
          request<ProviderListResponse>(server, `/provider${query}`),
          request<Record<string, ReadonlyArray<UpstreamMethod>>>(server, `/provider/auth${query}`),
          credentialTypes(profile.authPath)
        ])
        return (catalog.all ?? [])
          .map(
            (provider): OpenCodeAuthProvider => ({
              id: provider.id,
              name: provider.name,
              methods: methodValues(authMethods[provider.id]),
              ...(credentials[provider.id] === undefined
                ? {}
                : { credentialType: credentials[provider.id] })
            })
          )
          .sort((left, right) => left.name.localeCompare(right.name))
      } finally {
        if (server !== undefined) await server.stop()
        release()
      }
    },
    beginLogin: async (accountId, providerId, methodId, inputs, rawApiKey) => {
      const methodIndex = Number(methodId)
      if (!Number.isSafeInteger(methodIndex) || methodIndex < 0) {
        throw new Error("Unknown OpenCode authentication method")
      }
      const release = await acquire(accountId)
      let profile: OpenCodeProfile
      let server: OpenCodeServer
      try {
        profile = await config.profile(accountId)
        server = await startServer(profile)
      } catch (cause) {
        release()
        throw cause
      }
      const id = randomUUID()
      const flow: InternalFlow = {
        value: { id, accountId, providerId, state: "running" },
        methodIndex,
        server,
        workspaceQuery: workspaceQuery(profile),
        release,
        cancelled: false
      }
      flows.set(id, flow)
      try {
        const methods = await request<Record<string, ReadonlyArray<UpstreamMethod>>>(
          server,
          `/provider/auth${workspaceQuery(profile)}`
        )
        const upstream = methods[providerId]
        const candidates =
          upstream === undefined || upstream.length === 0
            ? [{ type: "api", label: "API key" }]
            : upstream
        const selected = candidates[methodIndex]
        if (selected === undefined || (selected.type !== "api" && selected.type !== "oauth")) {
          throw new Error("Unknown OpenCode authentication method")
        }
        if (selected.type === "api") {
          const apiKey = rawApiKey?.trim()
          if (apiKey === undefined || apiKey.length === 0) throw new Error("API key is required")
          await request<boolean>(server, `/auth/${encodeURIComponent(providerId)}`, {
            method: "PUT",
            body: JSON.stringify({
              type: "api",
              key: apiKey,
              ...(inputs === undefined || Object.keys(inputs).length === 0
                ? {}
                : { metadata: inputs })
            })
          })
          finish(flow, { id, accountId, providerId, state: "complete" })
          return structuredClone(flow.value)
        }

        const authorization = await request<AuthorizationResponse>(
          server,
          `/provider/${encodeURIComponent(providerId)}/oauth/authorize${workspaceQuery(profile)}`,
          {
            method: "POST",
            body: JSON.stringify({
              method: methodIndex,
              ...(inputs === undefined ? {} : { inputs })
            })
          }
        )
        if (
          authorization.url === undefined ||
          (authorization.method !== "auto" && authorization.method !== "code")
        ) {
          throw new Error("OpenCode did not return a usable authorization flow")
        }
        flow.value = {
          id,
          accountId,
          providerId,
          state: authorization.method === "code" ? "waiting" : "running",
          authorization: {
            url: authorization.url,
            method: authorization.method,
            instructions: authorization.instructions ?? ""
          }
        }
        if (authorization.method === "auto") void completeCallback(flow)
        return structuredClone(flow.value)
      } catch (cause) {
        fail(flow, cause)
        return structuredClone(flow.value)
      }
    },
    flow: (flowId) => {
      const flow = flows.get(flowId)
      if (flow === undefined) throw new Error("OpenCode authentication flow not found")
      return structuredClone(flow.value)
    },
    answer: async (flowId, rawCode) => {
      const flow = flows.get(flowId)
      if (flow === undefined) throw new Error("OpenCode authentication flow not found")
      if (flow.value.state !== "waiting" || flow.value.authorization?.method !== "code") {
        throw new Error("OpenCode authentication flow is not waiting for a code")
      }
      const code = rawCode.trim()
      if (code.length === 0) throw new Error("Authorization code is required")
      flow.value = { ...flow.value, state: "running" }
      await completeCallback(flow, code)
      return structuredClone(flow.value)
    },
    cancel: (flowId) => {
      const flow = flows.get(flowId)
      if (flow === undefined) return
      flow.cancelled = true
      void flow.server
        .stop()
        .catch(() => undefined)
        .finally(flow.release)
      flows.delete(flowId)
    },
    logout: async (accountId, providerId) => {
      const release = await acquire(accountId)
      let server: OpenCodeServer | undefined
      try {
        const profile = await config.profile(accountId)
        server = await startServer(profile)
        await request<boolean>(server, `/auth/${encodeURIComponent(providerId)}`, {
          method: "DELETE"
        })
      } finally {
        if (server !== undefined) await server.stop()
        release()
      }
    }
  }
}
