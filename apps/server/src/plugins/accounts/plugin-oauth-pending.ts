import { PluginOAuthSpec } from "@codevisor/api"
import { Schema } from "effect"

import type { PendingOAuthFlow } from "./plugin-account-oauth.js"

export interface PendingOAuthEntry {
  readonly flow: PendingOAuthFlow
  readonly spec: PluginOAuthSpec
}

export interface PendingOAuthStorage {
  readonly read: () => Promise<unknown>
  readonly write: (entries: ReadonlyArray<PendingOAuthEntry>) => Promise<void>
}

export interface PendingOAuthFlows {
  readonly add: (entry: PendingOAuthEntry) => Promise<void>
  readonly take: (flowId: string, nonce: string) => Promise<PendingOAuthEntry | undefined>
  readonly has: (flowId: string) => Promise<boolean>
}

export const memoryPendingOAuthStorage = (): PendingOAuthStorage => {
  let saved: ReadonlyArray<PendingOAuthEntry> = []
  return {
    read: async () => saved,
    write: async (entries) => {
      saved = entries
    }
  }
}

export const makePendingOAuthFlows = (
  storage: PendingOAuthStorage,
  now: () => number
): PendingOAuthFlows => {
  let loaded: Promise<Map<string, PendingOAuthEntry>> | undefined
  let writes: Promise<void> = Promise.resolve()

  const entries = (): Promise<Map<string, PendingOAuthEntry>> => {
    loaded ??= storage.read().then(
      (stored) => new Map(liveEntries(stored, now()).map((entry) => [entry.flow.flowId, entry])),
      () => new Map()
    )
    return loaded
  }

  const change = async <T>(apply: (pending: Map<string, PendingOAuthEntry>) => T): Promise<T> => {
    const pending = await entries()
    forgetExpired(pending, now())
    const result = apply(pending)
    const snapshot = [...pending.values()]
    writes = writes.then(() => storage.write(snapshot)).catch(() => undefined)
    await writes
    return result
  }

  return {
    add: (entry) =>
      change((pending) => {
        pending.set(entry.flow.flowId, entry)
      }),
    take: (flowId, nonce) =>
      change((pending) => {
        const entry = pending.get(flowId)
        if (entry?.flow.nonce !== nonce) return undefined

        pending.delete(flowId)
        return entry
      }),
    has: async (flowId) => {
      const entry = (await entries()).get(flowId)
      return entry !== undefined && entry.flow.expiresAt >= now()
    }
  }
}

const forgetExpired = (pending: Map<string, PendingOAuthEntry>, at: number): void => {
  for (const [flowId, entry] of pending) if (entry.flow.expiresAt < at) pending.delete(flowId)
}

const liveEntries = (stored: unknown, at: number): ReadonlyArray<PendingOAuthEntry> =>
  decodeEntries(stored).filter((entry) => entry.flow.expiresAt >= at)

const FieldValue = Schema.Union([Schema.String, Schema.Number, Schema.Boolean])

const PendingFlowSchema = Schema.Struct({
  flowId: Schema.String,
  nonce: Schema.String,
  serverId: Schema.String,
  plugin: Schema.String,
  accountId: Schema.optionalKey(Schema.String),
  label: Schema.optionalKey(Schema.String),
  values: Schema.Record(Schema.String, FieldValue),
  secrets: Schema.Record(Schema.String, Schema.String),
  client: Schema.Struct({
    clientId: Schema.String,
    clientSecret: Schema.optionalKey(Schema.String)
  }),
  redirectUri: Schema.String,
  codeVerifier: Schema.String,
  expiresAt: Schema.Number
})

const PendingEntriesSchema = Schema.Array(
  Schema.Struct({ flow: PendingFlowSchema, spec: PluginOAuthSpec })
)

const decodeEntries = (stored: unknown): ReadonlyArray<PendingOAuthEntry> => {
  const decoded = Schema.decodeUnknownOption(PendingEntriesSchema)(stored)
  return decoded._tag === "Some" ? decoded.value : []
}
