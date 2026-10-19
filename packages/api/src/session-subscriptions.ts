import { Schema } from "effect"

export const SessionEventType = Schema.Literals([
  "turn_ended",
  "waiting_for_user",
  "errored",
  "job_finished"
])
export type SessionEventType = typeof SessionEventType.Type

export const DEFAULT_SUBSCRIPTION_EVENTS: ReadonlyArray<SessionEventType> = [
  "turn_ended",
  "waiting_for_user",
  "errored"
]

export const SessionSubscription = Schema.Struct({
  id: Schema.String,
  subscriberSessionId: Schema.String,
  targetSessionId: Schema.String,
  events: Schema.Array(SessionEventType),
  once: Schema.Boolean,
  createdAt: Schema.String
})
export type SessionSubscription = typeof SessionSubscription.Type

export const CreateSessionSubscriptionRequest = Schema.Struct({
  targetSessionId: Schema.String,
  events: Schema.optional(Schema.Array(SessionEventType)),
  once: Schema.optional(Schema.Boolean)
})
export type CreateSessionSubscriptionRequest = typeof CreateSessionSubscriptionRequest.Type

export const SessionSubscriptionList = Schema.Struct({
  subscriptions: Schema.Array(SessionSubscription)
})
export type SessionSubscriptionList = typeof SessionSubscriptionList.Type
