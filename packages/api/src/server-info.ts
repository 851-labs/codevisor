import { Schema } from "effect"

export const ServerKind = Schema.Literals(["local", "remote"])
export type ServerKind = typeof ServerKind.Type

export const HealthResponse = Schema.Struct({
  ok: Schema.Boolean,
  version: Schema.String,
  database: Schema.Literals(["ready", "migrating", "failed"]),
  bootId: Schema.optional(Schema.String),
  processId: Schema.optional(Schema.Number),
  appOwned: Schema.optional(Schema.Boolean),
  buildNumber: Schema.optional(Schema.Number),
  sourceRevision: Schema.optional(Schema.String),
  serviceManaged: Schema.optional(Schema.Boolean),
  migration: Schema.optional(
    Schema.Struct({
      id: Schema.String,
      name: Schema.String,
      completed: Schema.Number,
      total: Schema.Number,
      error: Schema.optional(Schema.String)
    })
  )
})
export type HealthResponse = typeof HealthResponse.Type

export const MAX_UPLOAD_BYTES = 500 * 1024 * 1024

export const ServerInfo = Schema.Struct({
  id: Schema.String,
  name: Schema.String,
  kind: ServerKind,
  version: Schema.String,
  platform: Schema.String,
  bindHost: Schema.String,
  features: Schema.optional(Schema.Array(Schema.String)),
  machineId: Schema.optional(Schema.String),
  arch: Schema.optional(Schema.String),
  hostname: Schema.optional(Schema.String),
  maxUploadBytes: Schema.optional(Schema.Number),
  icon: Schema.optional(Schema.String)
})
export type ServerInfo = typeof ServerInfo.Type

export const DiscoveryInfo = Schema.Struct({
  serverId: Schema.String,
  machineId: Schema.String,
  name: Schema.String,
  kind: ServerKind,
  version: Schema.String,
  platform: Schema.String,
  hostname: Schema.String,
  cloudLinked: Schema.optional(Schema.Boolean)
})
export type DiscoveryInfo = typeof DiscoveryInfo.Type

export const UpdateApplyState = Schema.Struct({
  progress: Schema.optional(Schema.Number),
  state: Schema.Literals(["draining", "installing", "failed"]),
  message: Schema.optional(Schema.String),
  targetVersion: Schema.optional(Schema.String),
  targetBuildNumber: Schema.optional(Schema.Number),
  at: Schema.String
})
export type UpdateApplyState = typeof UpdateApplyState.Type

export const UpdateInfo = Schema.Struct({
  currentVersion: Schema.String,
  latestVersion: Schema.String,
  updateAvailable: Schema.Boolean,
  channel: Schema.String,
  checkedAt: Schema.optional(Schema.String),
  migrationState: Schema.Literals(["idle", "running", "failed"]),
  currentBuildNumber: Schema.optional(Schema.Number),
  latestBuildNumber: Schema.optional(Schema.Number),
  lastApply: Schema.optional(UpdateApplyState)
})
export type UpdateInfo = typeof UpdateInfo.Type

export const RestartDrainState = Schema.Struct({
  state: Schema.Literals(["idle", "draining", "drained"]),
  remaining: Schema.Number,
  startedAt: Schema.String,
  deadlineAt: Schema.optional(Schema.String)
})
export type RestartDrainState = typeof RestartDrainState.Type

export const RestartDrainRequest = Schema.Struct({
  interrupt: Schema.optional(Schema.Boolean),
  timeoutMs: Schema.optional(Schema.Number)
})
export type RestartDrainRequest = typeof RestartDrainRequest.Type

export const PairingTokenResponse = Schema.Struct({
  token: Schema.String,
  createdAt: Schema.String
})
export type PairingTokenResponse = typeof PairingTokenResponse.Type
