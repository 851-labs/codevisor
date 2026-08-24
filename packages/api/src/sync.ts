import { Schema } from "effect"

/// Wire schemas for the config plane: small replicated documents of
/// last-writer-wins entries, merged with hybrid-logical-clock timestamps.
/// The merge semantics live in @codevisor/sync; these are the shapes every
/// server replica exposes over /v1/sync/:namespace.

/// A hybrid logical clock stamp. Ordering: wallMs, then counter, then
/// deviceId as the deterministic tiebreak — every replica resolves any two
/// concurrent writes identically.
export const SyncTimestamp = Schema.Struct({
  wallMs: Schema.Number,
  counter: Schema.Number,
  deviceId: Schema.String
})
export type SyncTimestamp = typeof SyncTimestamp.Type

/// One replicated key. Deletions are tombstones (`deleted: true`) so a
/// removal wins over an older write on replicas that never saw the key.
export const SyncEntry = Schema.Struct({
  key: Schema.String,
  value: Schema.Unknown,
  deleted: Schema.optional(Schema.Boolean),
  timestamp: SyncTimestamp
})
export type SyncEntry = typeof SyncEntry.Type

/// A namespace's full replica state. Documents are deliberately small
/// (settings, inventories-of-references) — full-state exchange keeps the
/// protocol trivially convergent.
export const SyncDocument = Schema.Struct({
  namespace: Schema.String,
  entries: Schema.Array(SyncEntry)
})
export type SyncDocument = typeof SyncDocument.Type

/// Body of `PUT /v1/sync/:namespace`: entries to merge into the server's
/// replica. The response is the merged document, so one round trip both
/// pushes and pulls.
export const PutSyncRequest = Schema.Struct({
  entries: Schema.Array(SyncEntry)
})
export type PutSyncRequest = typeof PutSyncRequest.Type
