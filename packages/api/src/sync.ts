import { Schema } from "effect"

export const SyncTimestamp = Schema.Struct({
  wallMs: Schema.Number,
  counter: Schema.Number,
  deviceId: Schema.String
})
export type SyncTimestamp = typeof SyncTimestamp.Type

export const SyncEntry = Schema.Struct({
  key: Schema.String,
  value: Schema.Unknown,
  deleted: Schema.optional(Schema.Boolean),
  timestamp: SyncTimestamp
})
export type SyncEntry = typeof SyncEntry.Type

export const SyncDocument = Schema.Struct({
  namespace: Schema.String,
  entries: Schema.Array(SyncEntry)
})
export type SyncDocument = typeof SyncDocument.Type

export const PutSyncRequest = Schema.Struct({
  entries: Schema.Array(SyncEntry)
})
export type PutSyncRequest = typeof PutSyncRequest.Type
