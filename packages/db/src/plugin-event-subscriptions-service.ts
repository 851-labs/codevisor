import { randomUUID } from "node:crypto"

import { isoTimestamp } from "@codevisor/api"
import type { Effect } from "effect"

import { attempt, type DatabaseError } from "./errors.js"
import { canonicalUuid } from "./ids.js"
import { parseJsonObject } from "./json-column.js"
import { integer, nullable, rowReader, text } from "./row-reader.js"
import type { ServiceContext } from "./service-context.js"

export interface PluginEventSubscriptionRecord {
  readonly id: string
  readonly sessionId: string
  readonly serverId: string
  readonly accountId?: string
  readonly eventName: string
  readonly arguments: Readonly<Record<string, unknown>>
  readonly filter?: string
  readonly explained: string
  readonly note?: string
  readonly once: boolean
  readonly createdBy: "agent" | "user"
  readonly pausedReason?: string
  readonly createdAt: string
}

export type NewPluginEventSubscription = Omit<PluginEventSubscriptionRecord, "id" | "createdAt">

export interface PluginEventSubscriptionsService {
  readonly createPluginEventSubscription: (
    subscription: NewPluginEventSubscription
  ) => Effect.Effect<PluginEventSubscriptionRecord, DatabaseError>
  readonly listPluginEventSubscriptions: (
    sessionId?: string
  ) => Effect.Effect<ReadonlyArray<PluginEventSubscriptionRecord>, DatabaseError>
  readonly getPluginEventSubscription: (
    id: string
  ) => Effect.Effect<PluginEventSubscriptionRecord | undefined, DatabaseError>
  readonly deletePluginEventSubscription: (id: string) => Effect.Effect<boolean, DatabaseError>
  readonly pausePluginEventSubscription: (
    id: string,
    reason: string | undefined
  ) => Effect.Effect<void, DatabaseError>
}

export const makePluginEventSubscriptionsService = (
  context: ServiceContext
): PluginEventSubscriptionsService => {
  const { sqlite, getSession } = context

  return {
    createPluginEventSubscription: (subscription) =>
      attempt("createPluginEventSubscription", () => {
        const record = newSubscription(subscription)
        getSession(record.sessionId)
        sqlite.prepare(subscriptionSql.insert).run(...insertValues(record))
        return record
      }),
    listPluginEventSubscriptions: (sessionId) =>
      attempt("listPluginEventSubscriptions", () =>
        subscriptionsFor(sqlite, sessionId).map(subscriptionFromRow)
      ),
    getPluginEventSubscription: (id) =>
      attempt("getPluginEventSubscription", () => {
        const row = subscriptionRows.maybe(sqlite.prepare(subscriptionSql.byId).get(id))
        return row === undefined ? undefined : subscriptionFromRow(row)
      }),
    deletePluginEventSubscription: (id) =>
      attempt(
        "deletePluginEventSubscription",
        () => sqlite.prepare(subscriptionSql.delete).run(id).changes > 0
      ),
    pausePluginEventSubscription: (id, reason) =>
      attempt("pausePluginEventSubscription", () => {
        sqlite.prepare(subscriptionSql.pause).run(reason ?? null, id)
      })
  }
}

const subscriptionsFor = (sqlite: ServiceContext["sqlite"], sessionId: string | undefined) => {
  if (sessionId === undefined)
    return subscriptionRows.all(sqlite.prepare(subscriptionSql.all).all())
  return subscriptionRows.all(
    sqlite.prepare(subscriptionSql.bySession).all(canonicalUuid(sessionId))
  )
}

const newSubscription = (
  subscription: NewPluginEventSubscription
): PluginEventSubscriptionRecord => ({
  ...subscription,
  id: randomUUID(),
  sessionId: canonicalUuid(subscription.sessionId),
  createdAt: isoTimestamp()
})

const insertValues = (record: PluginEventSubscriptionRecord) =>
  [
    record.id,
    record.sessionId,
    record.serverId,
    record.accountId ?? null,
    record.eventName,
    JSON.stringify(record.arguments),
    record.filter ?? null,
    record.explained,
    record.note ?? null,
    Number(record.once),
    record.createdBy,
    record.pausedReason ?? null,
    record.createdAt
  ] as const

const subscriptionFromRow = (row: SubscriptionRow): PluginEventSubscriptionRecord => ({
  id: row.id,
  sessionId: row.session_id,
  serverId: row.server_id,
  ...(row.account_id === null ? {} : { accountId: row.account_id }),
  eventName: row.event_name,
  arguments: parseJsonObject(row.arguments),
  ...(row.filter === null ? {} : { filter: row.filter }),
  explained: row.explained,
  ...(row.note === null ? {} : { note: row.note }),
  once: row.once === 1,
  createdBy: row.created_by === "user" ? "user" : "agent",
  ...(row.paused_reason === null ? {} : { pausedReason: row.paused_reason }),
  createdAt: row.created_at
})

interface SubscriptionRow {
  readonly id: string
  readonly session_id: string
  readonly server_id: string
  readonly account_id: string | null
  readonly event_name: string
  readonly arguments: string
  readonly filter: string | null
  readonly explained: string
  readonly note: string | null
  readonly once: number
  readonly created_by: string
  readonly paused_reason: string | null
  readonly created_at: string
}

const subscriptionRows = rowReader<SubscriptionRow>({
  id: text,
  session_id: text,
  server_id: text,
  account_id: nullable(text),
  event_name: text,
  arguments: text,
  filter: nullable(text),
  explained: text,
  note: nullable(text),
  once: integer,
  created_by: text,
  paused_reason: nullable(text),
  created_at: text
})

const subscriptionSql = {
  insert: `insert into plugin_event_subscriptions
    (id, session_id, server_id, account_id, event_name, arguments, filter, explained, note, once,
     created_by, paused_reason, created_at)
    values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  all: "select * from plugin_event_subscriptions order by created_at, rowid",
  bySession:
    "select * from plugin_event_subscriptions where session_id = ? order by created_at, rowid",
  byId: "select * from plugin_event_subscriptions where id = ?",
  delete: "delete from plugin_event_subscriptions where id = ?",
  pause: "update plugin_event_subscriptions set paused_reason = ? where id = ?"
}
