import { randomUUID } from "node:crypto"

import { isoTimestamp } from "@codevisor/api"
import type { Effect } from "effect"

import { attempt, type DatabaseError } from "./errors.js"
import { integer, nullable, rowReader, text } from "./row-reader.js"
import type { ServiceContext } from "./service-context.js"

export interface PluginEventOccurrence {
  readonly serverId: string
  readonly accountId?: string
  readonly eventName: string
  readonly sourceEventId: string
  readonly occurredAt: string
  readonly data: unknown
}

export interface PluginEventStored extends PluginEventOccurrence {
  readonly id: string
  readonly receivedAt: string
}

export interface RecordedPluginEvent {
  readonly event: PluginEventStored
  readonly duplicate: boolean
}

export interface PendingPluginEventDelivery {
  readonly subscriptionId: string
  readonly event: PluginEventStored
}

export interface PluginEventsService {
  readonly recordPluginEvent: (
    occurrence: PluginEventOccurrence
  ) => Effect.Effect<RecordedPluginEvent, DatabaseError>
  readonly addPluginEventDelivery: (
    subscriptionId: string,
    eventId: string
  ) => Effect.Effect<boolean, DatabaseError>
  readonly pendingPluginEventDeliveries: Effect.Effect<
    ReadonlyArray<PendingPluginEventDelivery>,
    DatabaseError
  >
  readonly markPluginEventDelivered: (
    subscriptionId: string,
    eventId: string
  ) => Effect.Effect<void, DatabaseError>
  readonly countPluginEventDeliveriesSince: (
    subscriptionId: string,
    since: string
  ) => Effect.Effect<number, DatabaseError>
  readonly recentPluginEvents: (
    serverId: string,
    eventName: string,
    limit: number
  ) => Effect.Effect<ReadonlyArray<PluginEventStored>, DatabaseError>
  readonly getPluginEvent: (
    id: string
  ) => Effect.Effect<PluginEventStored | undefined, DatabaseError>
  readonly prunePluginEvents: (receivedBefore: string) => Effect.Effect<number, DatabaseError>
  readonly pluginEventCursor: (
    sourceKey: string
  ) => Effect.Effect<string | undefined, DatabaseError>
  readonly savePluginEventCursor: (
    sourceKey: string,
    cursor: string | undefined
  ) => Effect.Effect<void, DatabaseError>
}

export const makePluginEventsService = (context: ServiceContext): PluginEventsService => {
  const { sqlite } = context

  return {
    recordPluginEvent: (occurrence) =>
      attempt("recordPluginEvent", () => {
        const fresh = storedEvent(occurrence)
        const inserted = sqlite.prepare(eventSql.insert).run(...eventValues(fresh)).changes > 0
        if (inserted) return { event: fresh, duplicate: false }
        return { event: existingEvent(sqlite, occurrence), duplicate: true }
      }),
    addPluginEventDelivery: (subscriptionId, eventId) =>
      attempt(
        "addPluginEventDelivery",
        () =>
          sqlite.prepare(deliverySql.insert).run(subscriptionId, eventId, isoTimestamp()).changes >
          0
      ),
    pendingPluginEventDeliveries: attempt("pendingPluginEventDeliveries", () =>
      pendingRows.all(sqlite.prepare(deliverySql.pending).all()).map((row) => ({
        subscriptionId: row.subscription_id,
        event: eventFromRow(row)
      }))
    ),
    markPluginEventDelivered: (subscriptionId, eventId) =>
      attempt("markPluginEventDelivered", () => {
        sqlite.prepare(deliverySql.markDelivered).run(subscriptionId, eventId)
      }),
    countPluginEventDeliveriesSince: (subscriptionId, since) =>
      attempt("countPluginEventDeliveriesSince", () =>
        countOf(sqlite.prepare(deliverySql.countSince).get(subscriptionId, since))
      ),
    recentPluginEvents: (serverId, eventName, limit) =>
      attempt("recentPluginEvents", () =>
        eventRows
          .all(sqlite.prepare(eventSql.recent).all(serverId, eventName, limit))
          .map(eventFromRow)
      ),
    getPluginEvent: (id) =>
      attempt("getPluginEvent", () => {
        const row = eventRows.maybe(sqlite.prepare(eventSql.byId).get(id))
        return row === undefined ? undefined : eventFromRow(row)
      }),
    prunePluginEvents: (receivedBefore) =>
      attempt(
        "prunePluginEvents",
        () => sqlite.prepare(eventSql.pruneBefore).run(receivedBefore).changes
      ),
    pluginEventCursor: (sourceKey) =>
      attempt(
        "pluginEventCursor",
        () => cursorRows.maybe(sqlite.prepare(cursorSql.get).get(sourceKey))?.cursor ?? undefined
      ),
    savePluginEventCursor: (sourceKey, cursor) =>
      attempt("savePluginEventCursor", () => {
        sqlite.prepare(cursorSql.upsert).run(sourceKey, cursor ?? null, isoTimestamp())
      })
  }
}

const storedEvent = (occurrence: PluginEventOccurrence): PluginEventStored => ({
  ...occurrence,
  id: randomUUID(),
  receivedAt: isoTimestamp()
})

const existingEvent = (
  sqlite: ServiceContext["sqlite"],
  occurrence: PluginEventOccurrence
): PluginEventStored =>
  eventFromRow(
    eventRows.one(
      sqlite
        .prepare(eventSql.bySource)
        .get(
          occurrence.serverId,
          occurrence.accountId ?? "",
          occurrence.eventName,
          occurrence.sourceEventId
        )
    )
  )

const eventValues = (event: PluginEventStored) =>
  [
    event.id,
    event.serverId,
    event.accountId ?? "",
    event.eventName,
    event.sourceEventId,
    event.occurredAt,
    event.receivedAt,
    JSON.stringify(event.data ?? null)
  ] as const

const eventFromRow = (row: EventRow): PluginEventStored => ({
  id: row.id,
  serverId: row.server_id,
  ...(row.account_id === "" ? {} : { accountId: row.account_id }),
  eventName: row.event_name,
  sourceEventId: row.source_event_id,
  occurredAt: row.occurred_at,
  receivedAt: row.received_at,
  data: JSON.parse(row.data) as unknown
})

const countOf = (row: unknown): number => countRows.one(row).count

interface EventRow {
  readonly id: string
  readonly server_id: string
  readonly account_id: string
  readonly event_name: string
  readonly source_event_id: string
  readonly occurred_at: string
  readonly received_at: string
  readonly data: string
}

interface PendingRow extends EventRow {
  readonly subscription_id: string
}

const eventColumns = {
  id: text,
  server_id: text,
  account_id: text,
  event_name: text,
  source_event_id: text,
  occurred_at: text,
  received_at: text,
  data: text
}

const eventRows = rowReader<EventRow>(eventColumns)

const pendingRows = rowReader<PendingRow>({ ...eventColumns, subscription_id: text })

const countRows = rowReader<{ readonly count: number }>({ count: integer })

const cursorRows = rowReader<{ readonly cursor: string | null }>({ cursor: nullable(text) })

const eventSql = {
  insert: `insert or ignore into plugin_events
    (id, server_id, account_id, event_name, source_event_id, occurred_at, received_at, data)
    values (?, ?, ?, ?, ?, ?, ?, ?)`,
  bySource: `select * from plugin_events
    where server_id = ? and account_id = ? and event_name = ? and source_event_id = ?`,
  byId: "select * from plugin_events where id = ?",
  recent: `select * from plugin_events where server_id = ? and event_name = ?
    order by received_at desc, rowid desc limit ?`,
  pruneBefore: `delete from plugin_events where received_at < ?
    and id not in (select event_id from plugin_event_deliveries where state = 'pending')`
}

const deliverySql = {
  insert: `insert or ignore into plugin_event_deliveries
    (subscription_id, event_id, state, created_at) values (?, ?, 'pending', ?)`,
  pending: `select e.*, d.subscription_id from plugin_event_deliveries d
    join plugin_events e on e.id = d.event_id
    where d.state = 'pending' order by d.created_at, d.rowid`,
  markDelivered: `update plugin_event_deliveries set state = 'delivered'
    where subscription_id = ? and event_id = ?`,
  countSince: `select count(*) as count from plugin_event_deliveries
    where subscription_id = ? and state = 'delivered' and created_at >= ?`
}

const cursorSql = {
  get: "select cursor from plugin_event_cursors where source_key = ?",
  upsert: `insert into plugin_event_cursors (source_key, cursor, updated_at) values (?, ?, ?)
    on conflict(source_key) do update set cursor = excluded.cursor, updated_at = excluded.updated_at`
}
