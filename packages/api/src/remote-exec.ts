import { Schema } from "effect"

export const EXEC_DEFAULT_TIMEOUT_MS = 120_000
export const EXEC_MAX_TIMEOUT_MS = 600_000
export const FLEET_EXEC_TASK_PATH = "fleet.exec_task"
export const FLEET_EXEC_CONTROL_PATH = "fleet.exec_control"
export const FLEET_MIRROR_PATH = "fleet.mirror"

export const ExecRequest = Schema.Struct({
  command: Schema.String,
  description: Schema.optional(Schema.String),
  timeout: Schema.optional(Schema.Number),
  run_in_background: Schema.optional(Schema.Boolean),
  cwd: Schema.optional(Schema.String),
  callerAgentId: Schema.optional(Schema.String)
})
export type ExecRequest = typeof ExecRequest.Type

export const ExecTaskState = Schema.Literals(["running", "exited", "stopped"])
export type ExecTaskState = typeof ExecTaskState.Type

export const ExecTask = Schema.Struct({
  taskId: Schema.String,
  command: Schema.String,
  description: Schema.String,
  cwd: Schema.String,
  state: ExecTaskState,
  exitCode: Schema.optional(Schema.NullOr(Schema.Number)),
  startedAt: Schema.String,
  finishedAt: Schema.optional(Schema.String),
  outputPath: Schema.String
})
export type ExecTask = typeof ExecTask.Type

export const ExecTaskEvent = Schema.Struct({
  sessionId: Schema.String,
  task: ExecTask,
  outputTail: Schema.String
})
export type ExecTaskEvent = typeof ExecTaskEvent.Type

export const FleetExecControl = Schema.Union([
  Schema.Struct({ action: Schema.Literal("stop"), taskId: Schema.String }),
  Schema.Struct({ action: Schema.Literal("output"), taskId: Schema.String, lines: Schema.Number })
])
export type FleetExecControl = typeof FleetExecControl.Type

export const RemoteExecTask = Schema.Struct({
  taskId: Schema.String,
  sessionId: Schema.String,
  machine: Schema.Struct({ machineId: Schema.String, name: Schema.String }),
  description: Schema.String,
  command: Schema.String,
  startedAt: Schema.String,
  outputPath: Schema.String
})
export type RemoteExecTask = typeof RemoteExecTask.Type

export const WorkspaceSyncStartRequest = Schema.Struct({ machine: Schema.String })
export type WorkspaceSyncStartRequest = typeof WorkspaceSyncStartRequest.Type

export const WorkspaceSyncWaitRequest = Schema.Struct({ timeoutMs: Schema.optional(Schema.Number) })
export type WorkspaceSyncWaitRequest = typeof WorkspaceSyncWaitRequest.Type

export const WorkspaceSyncState = Schema.Literals(["syncing", "synced", "failed"])
export type WorkspaceSyncState = typeof WorkspaceSyncState.Type

export const WorkspaceSyncStatus = Schema.Struct({
  workspaceId: Schema.String,
  machine: Schema.Struct({ machineId: Schema.String, name: Schema.String }),
  path: Schema.optional(Schema.String),
  state: WorkspaceSyncState,
  pendingChanges: Schema.Boolean,
  lastSyncedAt: Schema.optional(Schema.String),
  lastSync: Schema.optional(
    Schema.Struct({ files: Schema.Number, bytes: Schema.Number, ms: Schema.Number })
  ),
  skipped: Schema.Array(Schema.String),
  error: Schema.optional(Schema.String)
})
export type WorkspaceSyncStatus = typeof WorkspaceSyncStatus.Type

export const FleetMirrorAction = Schema.Union([
  Schema.Struct({
    action: Schema.Literal("prepare"),
    mirrorId: Schema.String,
    name: Schema.String
  }),
  Schema.Struct({
    action: Schema.Literal("write"),
    mirrorId: Schema.String,
    offset: Schema.Number,
    data: Schema.String
  }),
  Schema.Struct({
    action: Schema.Literal("apply"),
    mirrorId: Schema.String,
    commit: Schema.String
  }),
  Schema.Struct({ action: Schema.Literal("remove"), mirrorId: Schema.String })
])
export type FleetMirrorAction = typeof FleetMirrorAction.Type
