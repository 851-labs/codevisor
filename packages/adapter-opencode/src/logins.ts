import { randomUUID } from "node:crypto"

import type { OpenCodeAuthFlow } from "@codevisor/api"
import { Schema } from "effect"

import { record, responseData, responseList } from "./internal.js"
import type { OpenCodeServer } from "./server.js"

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
  readonly capture?: (credential: Record<string, unknown>) => Promise<void>
}

const attemptStart = responseData(
  Schema.Struct({
    attemptID: Schema.String,
    url: Schema.String,
    instructions: Schema.String,
    mode: Schema.Literals(["auto", "code"])
  })
)

const attemptStatus = responseData(
  Schema.Struct({ status: Schema.String, message: Schema.optionalKey(Schema.String) })
)

const storedCredentials = responseList(
  Schema.Struct({
    integrationID: Schema.String,
    active: Schema.Boolean,
    value: Schema.Record(Schema.String, Schema.Unknown)
  })
)

interface Flow {
  value: OpenCodeAuthFlow
  readonly hold: OpenCodeServerHold
  readonly attemptPath: string
  readonly location: string
  readonly request: OpenCode2LoginRequest
  ended: boolean
}

export const authFileCredential = (value: Record<string, unknown>): Record<string, unknown> => {
  const metadata = record(value.metadata) ?? {}
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

const finish = async (flow: Flow, value: OpenCodeAuthFlow) => {
  if (flow.ended) return
  flow.ended = true
  flow.value = value
  await flow.hold.release()
}

export const makeOpenCode2Logins = (
  deps: {
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
      const stored = storedCredentials(await flow.hold.server.request("/api/credential"))
      const credential = stored.find(
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
        const data = attemptStatus(
          await flow.hold.server.request(flow.attemptPath, { location: flow.location })
        )
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
        await hold.server.request("/api/integration", { location })
        if (request.apiKey !== undefined) {
          await hold.server.request(`${integration}/connect/key`, {
            location,
            body: { key: request.apiKey, ...(request.inputs ? { answer: request.inputs } : {}) }
          })
          await hold.release()
          return { ...base, state: "complete" }
        }
        const attempt = attemptStart(
          await hold.server.request(`${integration}/connect/oauth`, {
            location,
            body: {
              methodID: request.methodId,
              ...(request.inputs ? { answer: request.inputs } : {})
            }
          })
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
