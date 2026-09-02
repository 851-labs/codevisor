import type { OpenCodeAuthFlow, OpenCodeAuthProvider } from "@codevisor/api"
import { randomUUID } from "node:crypto"
import { homedir } from "node:os"
import { join } from "node:path"
import {
  credentialTypes,
  failureMessage,
  methodValues,
  request,
  startServer,
  workspaceQuery,
  type AuthorizationResponse,
  type OpenCodeProfile,
  type OpenCodeServer,
  type ProviderListResponse,
  type UpstreamMethod
} from "./opencode-auth-server.js"

export type { OpenCodeProfile } from "./opencode-auth-server.js"

interface InternalFlow {
  value: OpenCodeAuthFlow
  readonly methodIndex: number
  readonly server: OpenCodeServer
  readonly workspaceQuery: string
  readonly release: () => void
  cancelled: boolean
}

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
