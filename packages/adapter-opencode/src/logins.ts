import { randomUUID } from "node:crypto"

import type { OpenCodeAuthFlow } from "@codevisor/api"

import type { OpenCodeServer } from "./server.js"

/// Sign-in flows against an OpenCode 2 server. OpenCode runs the OAuth
/// exchange itself (it hosts the browser callback or polls the device code);
/// Codevisor starts an attempt, relays its URL and instructions, and watches
/// it until OpenCode stores the credential, which may then be captured.

/// A server held for the flow's lifetime, handed back when it ends.
export interface OpenCodeServerHold {
  readonly server: OpenCodeServer
  readonly release: () => void | Promise<void>
}

export interface OpenCode2LoginRequest {
  readonly accountId: string
  readonly providerId: string
  readonly methodId: string
  readonly inputs?: Readonly<Record<string, string>>
  readonly apiKey?: string
  /// Takes the credential OpenCode stored (in auth.json's shape), e.g. into
  /// Codevisor's vault. Without it the credential stays where it landed.
  readonly capture?: (credential: Record<string, unknown>) => Promise<void>
}

interface Attempt {
  readonly attemptID: string
  readonly url: string
  readonly instructions: string
  readonly mode: "auto" | "code"
}

interface Flow {
  value: OpenCodeAuthFlow
  readonly hold: OpenCodeServerHold
  readonly attemptPath: string
  readonly location: string
  readonly request: OpenCode2LoginRequest
  ended: boolean
}

/// OpenCode 2 stores `{methodID, refresh, access, expires, metadata}`;
/// Codevisor's shared-account parser reads auth.json's `{refresh, access,
/// expires, accountId, enterpriseUrl}`.
export const authFileCredential = (value: Record<string, unknown>): Record<string, unknown> => {
  const metadata = (value.metadata ?? {}) as Record<string, unknown>
  return {
    type: "oauth",
    refresh: value.refresh,
    access: value.access,
    expires: value.expires,
    ...(typeof metadata.accountID === "string" ? { accountId: metadata.accountID } : {}),
    ...(typeof metadata.enterpriseUrl === "string" ? { enterpriseUrl: metadata.enterpriseUrl } : {})
  }
}

const message = (cause: unknown) => (cause instanceof Error ? cause.message : String(cause))

/// Settles a flow once, handing its server back.
const finish = async (flow: Flow, value: OpenCodeAuthFlow) => {
  if (flow.ended) return
  flow.ended = true
  flow.value = value
  await flow.hold.release()
}

export const makeOpenCode2Logins = (
  deps: {
    /// Resolves after `ms`; injected so the polling cadence is testable.
    readonly wait?: (ms: number) => Promise<void>
    readonly pollMs?: number
  } = {}
) => {
  const wait =
    deps.wait ?? ((ms: number) => new Promise<void>((done) => setTimeout(done, ms).unref()))
  const pollMs = deps.pollMs ?? 1_000
  const flows = new Map<string, Flow>()

  const complete = async (flow: Flow) => {
    const { providerId } = flow.request
    if (flow.request.capture !== undefined) {
      const stored = await flow.hold.server.request<{
        readonly data: ReadonlyArray<{
          readonly integrationID: string
          readonly active: boolean
          readonly value: Record<string, unknown>
        }>
      }>("/api/credential")
      const credential = stored.data.find(
        (entry) =>
          entry.integrationID === providerId && entry.active && entry.value.type === "oauth"
      )
      if (credential === undefined)
        throw new Error("OpenCode finished signing in but saved no credential.")
      await flow.request.capture(authFileCredential(credential.value))
    }
    await finish(flow, { ...flow.value, state: "complete" })
  }

  const watch = async (flow: Flow) => {
    try {
      while (!flow.ended) {
        await wait(pollMs)
        if (flow.ended) return
        const { data } = await flow.hold.server.request<{
          readonly data: { readonly status: string; readonly message?: string }
        }>(flow.attemptPath, { location: flow.location })
        if (flow.ended) return
        if (data.status === "complete") return await complete(flow)
        if (data.status !== "pending")
          return await finish(flow, {
            ...flow.value,
            state: "error",
            error:
              data.message ??
              (data.status === "expired" ? "Sign-in timed out. Try again." : "Sign-in failed.")
          })
      }
    } catch (cause) {
      await finish(flow, { ...flow.value, state: "error", error: message(cause) })
    }
  }

  return {
    begin: async (
      hold: OpenCodeServerHold,
      location: string,
      request: OpenCode2LoginRequest
    ): Promise<OpenCodeAuthFlow> => {
      const id = randomUUID()
      const base = { id, accountId: request.accountId, providerId: request.providerId }
      const integration = `/api/integration/${encodeURIComponent(request.providerId)}`
      try {
        // A location loads its integrations lazily; connecting before they
        // have loaded fails (OpenCode 2.0.24 answers 500).
        await hold.server.request("/api/integration", { location })
        if (request.apiKey !== undefined) {
          await hold.server.request(`${integration}/connect/key`, {
            location,
            body: { key: request.apiKey, ...(request.inputs ? { answer: request.inputs } : {}) }
          })
          await hold.release()
          return { ...base, state: "complete" }
        }
        const { data: attempt } = await hold.server.request<{ readonly data: Attempt }>(
          `${integration}/connect/oauth`,
          {
            location,
            body: {
              methodID: request.methodId,
              ...(request.inputs ? { answer: request.inputs } : {})
            }
          }
        )
        const flow: Flow = {
          value: {
            ...base,
            state: "running",
            authorization: {
              url: attempt.url,
              method: attempt.mode,
              instructions: attempt.instructions
            }
          },
          hold,
          attemptPath: `${integration}/connect/oauth/${encodeURIComponent(attempt.attemptID)}`,
          location,
          request,
          ended: false
        }
        flows.set(id, flow)
        void watch(flow)
        return flow.value
      } catch (cause) {
        await hold.release()
        throw cause
      }
    },
    flow: (flowId: string): OpenCodeAuthFlow | undefined => flows.get(flowId)?.value,
    /// For a sign-in that ends with a pasted code.
    answer: async (flowId: string, code: string): Promise<OpenCodeAuthFlow | undefined> => {
      const flow = flows.get(flowId)
      if (flow === undefined || flow.ended) return flow?.value
      try {
        await flow.hold.server.request(`${flow.attemptPath}/complete`, {
          location: flow.location,
          body: { code }
        })
      } catch (cause) {
        await finish(flow, { ...flow.value, state: "error", error: message(cause) })
      }
      return flow.value
    },
    cancel: async (flowId: string): Promise<boolean> => {
      const flow = flows.get(flowId)
      if (flow === undefined) return false
      flows.delete(flowId)
      if (flow.ended) return true
      await flow.hold.server
        .request(flow.attemptPath, { location: flow.location, method: "DELETE" })
        .catch(() => undefined)
      await finish(flow, { ...flow.value, state: "error", error: "Sign-in cancelled." })
      return true
    }
  }
}
