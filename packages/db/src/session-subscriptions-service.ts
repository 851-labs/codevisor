import { randomUUID } from "node:crypto"

import { isoTimestamp, SessionEventType, type SessionSubscription } from "@codevisor/api"
import { Schema, type Effect } from "effect"

import { attempt, type DatabaseError } from "./errors.js"
import { canonicalUuid } from "./ids.js"
import { parseJsonColumn } from "./json-column.js"
import { integer, rowReader, text } from "./row-reader.js"
import type { ServiceContext } from "./service-context.js"

export interface SessionSubscriptionRecord {
  readonly subscriberSessionId: string
  readonly targetSessionId: string
  readonly events: ReadonlyArray<SessionEventType>
  readonly once: boolean
}

export interface SessionSubscriptionsService {
  readonly createSessionSubscription: (
    record: SessionSubscriptionRecord
  ) => Effect.Effect<SessionSubscription, DatabaseError>
  readonly listSessionSubscriptions: (
    subscriberSessionId: string
  ) => Effect.Effect<ReadonlyArray<SessionSubscription>, DatabaseError>
  readonly listSubscriptionsTargeting: (
    targetSessionId: string
  ) => Effect.Effect<ReadonlyArray<SessionSubscription>, DatabaseError>
  readonly deleteSessionSubscription: (id: string) => Effect.Effect<boolean, DatabaseError>
}

export const makeSessionSubscriptionsService = (
  context: ServiceContext
): SessionSubscriptionsService => {
  const { sqlite, getSession } = context

  return {
    createSessionSubscription: (record) =>
      attempt("createSessionSubscription", () => {
        const subscription = newSubscription(record)
        getSession(subscription.subscriberSessionId)
        getSession(subscription.targetSessionId)
        sqlite.prepare(subscriptionSql.insert).run(...insertValues(subscription))
        return subscription
      }),
    listSessionSubscriptions: (subscriberSessionId) =>
      attempt("listSessionSubscriptions", () =>
        subscriptionRows
          .all(sqlite.prepare(subscriptionSql.bySubscriber).all(canonicalUuid(subscriberSessionId)))
          .map(subscriptionFromRow)
      ),
    listSubscriptionsTargeting: (targetSessionId) =>
      attempt("listSubscriptionsTargeting", () =>
        subscriptionRows
          .all(sqlite.prepare(subscriptionSql.byTarget).all(canonicalUuid(targetSessionId)))
          .map(subscriptionFromRow)
      ),
    deleteSessionSubscription: (id) =>
      attempt(
        "deleteSessionSubscription",
        () => sqlite.prepare(subscriptionSql.delete).run(id).changes > 0
      )
  }
}

const newSubscription = (record: SessionSubscriptionRecord): SessionSubscription => ({
  id: randomUUID(),
  subscriberSessionId: canonicalUuid(record.subscriberSessionId),
  targetSessionId: canonicalUuid(record.targetSessionId),
  events: [...new Set(record.events)],
  once: record.once,
  createdAt: isoTimestamp()
})

const insertValues = (subscription: SessionSubscription) =>
  [
    subscription.id,
    subscription.subscriberSessionId,
    subscription.targetSessionId,
    JSON.stringify(subscription.events),
    Number(subscription.once),
    subscription.createdAt
  ] as const

const subscriptionFromRow = (row: SessionSubscriptionRow): SessionSubscription => ({
  id: row.id,
  subscriberSessionId: row.subscriber_session_id,
  targetSessionId: row.target_session_id,
  events: parseJsonColumn(SessionEventTypes, row.events),
  once: row.once === 1,
  createdAt: row.created_at
})

const SessionEventTypes = Schema.Array(SessionEventType)

interface SessionSubscriptionRow {
  readonly id: string
  readonly subscriber_session_id: string
  readonly target_session_id: string
  readonly events: string
  readonly once: number
  readonly created_at: string
}

const subscriptionRows = rowReader<SessionSubscriptionRow>({
  id: text,
  subscriber_session_id: text,
  target_session_id: text,
  events: text,
  once: integer,
  created_at: text
})

const subscriptionSql = {
  insert: `insert into session_subscriptions
    (id, subscriber_session_id, target_session_id, events, once, created_at)
    values (?, ?, ?, ?, ?, ?)`,
  bySubscriber:
    "select * from session_subscriptions where subscriber_session_id = ? order by created_at, rowid",
  byTarget:
    "select * from session_subscriptions where target_session_id = ? order by created_at, rowid",
  delete: "delete from session_subscriptions where id = ?"
}
