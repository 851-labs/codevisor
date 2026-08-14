import type { AuthEvent, AuthPrompt, Credential, Provider } from "@earendil-works/pi-ai"
import { builtinProviders } from "@earendil-works/pi-ai/providers/all"
import type {
  PiAuthEvent,
  PiAuthMethod,
  PiAuthPrompt,
  PiAuthProvider,
  PiAuthProviderFlow
} from "@codevisor/api"
import { randomUUID } from "node:crypto"
import { chmod, mkdir, readFile, writeFile } from "node:fs/promises"
import { homedir } from "node:os"
import { dirname, join } from "node:path"
import lockfile from "proper-lockfile"

type AuthFile = Record<string, Credential>

interface PendingPrompt {
  readonly id: string
  readonly resolve: (value: string) => void
  readonly reject: (cause: Error) => void
}

interface InternalFlow {
  value: PiAuthProviderFlow
  revision: number
  readonly abort: AbortController
  pending: PendingPrompt | undefined
  readonly waiters: Set<() => void>
}

export interface PiAuthManagerConfig {
  readonly resolveEnv: () => Promise<NodeJS.ProcessEnv>
  readonly providers?: ReadonlyArray<Provider>
}

export interface PiAuthManager {
  readonly providers: () => Promise<ReadonlyArray<PiAuthProvider>>
  readonly beginLogin: (providerId: string, method: PiAuthMethod) => Promise<PiAuthProviderFlow>
  readonly flow: (flowId: string) => PiAuthProviderFlow
  readonly answer: (flowId: string, value: string) => Promise<PiAuthProviderFlow>
  readonly cancel: (flowId: string) => void
  readonly logout: (providerId: string) => Promise<void>
}

const publicFlow = (flow: InternalFlow): PiAuthProviderFlow => structuredClone(flow.value)

export const makePiAuthManager = (config: PiAuthManagerConfig): PiAuthManager => {
  const catalog = config.providers ?? builtinProviders()
  const flows = new Map<string, InternalFlow>()

  const authPath = async (): Promise<string> => {
    const env = await config.resolveEnv()
    const custom = env.PI_CODING_AGENT_DIR?.trim()
    return custom && custom.length > 0
      ? join(custom.replace(/^~(?=$|\/)/, env.HOME ?? homedir()), "auth.json")
      : join(env.HOME ?? homedir(), ".pi", "agent", "auth.json")
  }

  const ensureAuthFile = async (path: string): Promise<void> => {
    await mkdir(dirname(path), { recursive: true, mode: 0o700 })
    try {
      await writeFile(path, "{}", { encoding: "utf8", flag: "wx", mode: 0o600 })
    } catch (cause) {
      if ((cause as NodeJS.ErrnoException).code !== "EEXIST") throw cause
    }
    await chmod(path, 0o600)
  }

  const readCredentials = async (): Promise<AuthFile> => {
    try {
      return JSON.parse(await readFile(await authPath(), "utf8")) as AuthFile
    } catch (cause) {
      if ((cause as NodeJS.ErrnoException).code === "ENOENT") return {}
      throw cause
    }
  }

  const modifyCredentials = async (change: (current: AuthFile) => AuthFile): Promise<void> => {
    const path = await authPath()
    await ensureAuthFile(path)
    const release = await lockfile.lock(path, {
      realpath: false,
      retries: { retries: 10, factor: 2, minTimeout: 50, maxTimeout: 1_000 }
    })
    try {
      const current = JSON.parse(await readFile(path, "utf8")) as AuthFile
      await writeFile(path, `${JSON.stringify(change(current), null, 2)}\n`, {
        encoding: "utf8",
        mode: 0o600
      })
      await chmod(path, 0o600)
    } finally {
      await release()
    }
  }

  const findProvider = (providerId: string): Provider => {
    const provider = catalog.find((candidate) => candidate.id === providerId)
    if (provider === undefined) throw new Error(`Unknown Pi provider: ${providerId}`)
    return provider
  }

  const update = (flow: InternalFlow, value: PiAuthProviderFlow): void => {
    flow.value = value
    flow.revision += 1
    for (const wake of flow.waiters) wake()
    flow.waiters.clear()
  }

  const waitForUpdate = async (
    flow: InternalFlow,
    revision: number,
    timeoutMs = 150
  ): Promise<void> => {
    if (flow.revision !== revision) return
    await new Promise<void>((resolve) => {
      const timer = setTimeout(() => {
        flow.waiters.delete(wake)
        resolve()
      }, timeoutMs)
      const wake = () => {
        clearTimeout(timer)
        resolve()
      }
      flow.waiters.add(wake)
    })
  }

  const promptValue = (prompt: AuthPrompt): PiAuthPrompt => ({
    id: randomUUID(),
    type: prompt.type,
    message: prompt.message,
    ...(!("placeholder" in prompt) || prompt.placeholder === undefined
      ? {}
      : { placeholder: prompt.placeholder }),
    options: prompt.type === "select" ? [...prompt.options] : []
  })

  const eventValue = (event: AuthEvent): PiAuthEvent => {
    switch (event.type) {
      case "auth_url":
        return {
          type: event.type,
          url: event.url,
          ...(event.instructions === undefined ? {} : { message: event.instructions })
        }
      case "device_code":
        return {
          type: event.type,
          userCode: event.userCode,
          verificationUrl: event.verificationUri
        }
      case "info":
        return {
          type: event.type,
          message: event.message,
          ...(event.links?.[0]?.url === undefined ? {} : { url: event.links[0].url })
        }
      case "progress":
        return { type: event.type, message: event.message }
    }
  }

  const runLogin = async (
    flow: InternalFlow,
    provider: Provider,
    method: PiAuthMethod
  ): Promise<void> => {
    try {
      const login = method === "oauth" ? provider.auth.oauth?.login : provider.auth.apiKey?.login
      if (login === undefined) throw new Error(`${provider.name} does not support ${method}`)
      const credential = await login({
        signal: flow.abort.signal,
        notify: (event) => {
          update(flow, {
            id: flow.value.id,
            providerId: provider.id,
            state: "running",
            event: eventValue(event)
          })
        },
        prompt: (prompt) => {
          if (flow.abort.signal.aborted) return Promise.reject(new Error("Login cancelled"))
          const visible = promptValue(prompt)
          return new Promise<string>((resolve, reject) => {
            const pending: PendingPrompt = { id: visible.id, resolve, reject }
            flow.pending = pending
            const rejectPrompt = () => {
              if (flow.pending?.id === pending.id) flow.pending = undefined
              reject(new Error("Login cancelled"))
            }
            prompt.signal?.addEventListener("abort", rejectPrompt, { once: true })
            update(flow, {
              id: flow.value.id,
              providerId: provider.id,
              state: "waiting",
              prompt: visible,
              ...(flow.value.event === undefined ? {} : { event: flow.value.event })
            })
          })
        }
      })
      if (flow.abort.signal.aborted) throw new Error("Login cancelled")
      await modifyCredentials((current) => ({ ...current, [provider.id]: credential }))
      flow.pending = undefined
      update(flow, { id: flow.value.id, providerId: provider.id, state: "complete" })
    } catch (cause) {
      flow.pending = undefined
      update(flow, {
        id: flow.value.id,
        providerId: provider.id,
        state: "error",
        error: cause instanceof Error ? cause.message : String(cause)
      })
    }
  }

  return {
    providers: async () => {
      const credentials = await readCredentials()
      return catalog
        .map((provider): PiAuthProvider | undefined => {
          const credential = credentials[provider.id]
          const methods: PiAuthMethod[] = []
          if (provider.auth.oauth !== undefined) methods.push("oauth")
          if (provider.auth.apiKey?.login !== undefined) methods.push("api_key")
          if (methods.length === 0 && credential === undefined) return undefined
          return {
            id: provider.id,
            name: provider.name,
            methods,
            ...(credential === undefined ? {} : { credentialType: credential.type })
          }
        })
        .filter((provider): provider is PiAuthProvider => provider !== undefined)
        .sort((left, right) => left.name.localeCompare(right.name))
    },
    beginLogin: async (providerId, method) => {
      const provider = findProvider(providerId)
      const id = randomUUID()
      const flow: InternalFlow = {
        value: { id, providerId, state: "running" },
        revision: 0,
        abort: new AbortController(),
        pending: undefined,
        waiters: new Set()
      }
      flows.set(id, flow)
      const revision = flow.revision
      void runLogin(flow, provider, method)
      await waitForUpdate(flow, revision)
      return publicFlow(flow)
    },
    flow: (flowId) => {
      const flow = flows.get(flowId)
      if (flow === undefined) throw new Error("Pi authentication flow not found")
      return publicFlow(flow)
    },
    answer: async (flowId, value) => {
      const flow = flows.get(flowId)
      if (flow === undefined) throw new Error("Pi authentication flow not found")
      const pending = flow.pending
      if (pending === undefined || flow.value.prompt?.id !== pending.id) {
        throw new Error("Pi authentication flow is not waiting for input")
      }
      flow.pending = undefined
      const revision = flow.revision
      update(flow, { id: flow.value.id, providerId: flow.value.providerId, state: "running" })
      pending.resolve(value)
      await waitForUpdate(flow, revision + 1, 500)
      return publicFlow(flow)
    },
    cancel: (flowId) => {
      const flow = flows.get(flowId)
      if (flow === undefined) return
      flow.abort.abort()
      flow.pending?.reject(new Error("Login cancelled"))
      flow.pending = undefined
      flows.delete(flowId)
    },
    logout: async (providerId) => {
      findProvider(providerId)
      await modifyCredentials((current) => {
        const next = { ...current }
        delete next[providerId]
        return next
      })
    }
  }
}
