import { Schema } from "effect"

export const MachineSummary = Schema.Struct({
  id: Schema.String,
  name: Schema.String,
  os: Schema.optional(Schema.String),
  online: Schema.Boolean,
  lastSeen: Schema.optional(Schema.String),
  isCurrent: Schema.Boolean,
  addedBy: Schema.optional(Schema.String)
})
export type MachineSummary = typeof MachineSummary.Type

export const MachinesResponse = Schema.Struct({ machines: Schema.Array(MachineSummary) })
export type MachinesResponse = typeof MachinesResponse.Type

export const MachineInviteResponse = Schema.Struct({
  code: Schema.String,
  expiresAt: Schema.String
})
export type MachineInviteResponse = typeof MachineInviteResponse.Type

export const AddMachineRequest = Schema.Struct({
  ssh: Schema.String,
  name: Schema.optional(Schema.String),
  sshPort: Schema.optional(Schema.Number)
})
export type AddMachineRequest = typeof AddMachineRequest.Type

export const AddMachineResponse = Schema.Struct({ machine: MachineSummary })
export type AddMachineResponse = typeof AddMachineResponse.Type

export const MachineCallOrigin = Schema.Struct({
  machineId: Schema.String,
  machineName: Schema.String,
  sessionId: Schema.optional(Schema.String),
  sessionTitle: Schema.optional(Schema.String),
  clientId: Schema.optional(Schema.String)
})
export type MachineCallOrigin = typeof MachineCallOrigin.Type

export const GatewayInvokeRequest = Schema.Struct({
  path: Schema.String,
  args: Schema.optional(Schema.Unknown),
  origin: MachineCallOrigin
})
export type GatewayInvokeRequest = typeof GatewayInvokeRequest.Type

export const GatewayInvokeResponse = Schema.Struct({ result: Schema.Unknown })
export type GatewayInvokeResponse = typeof GatewayInvokeResponse.Type

export const MachineStatsUsage = Schema.Struct({
  usedBytes: Schema.Number,
  totalBytes: Schema.Number
})
export type MachineStatsUsage = typeof MachineStatsUsage.Type

export const MachineLoadSample = Schema.Struct({
  at: Schema.String,
  usedPercent: Schema.Number
})
export type MachineLoadSample = typeof MachineLoadSample.Type

export const MachineStats = Schema.Struct({
  sampledAt: Schema.String,
  uptimeSeconds: Schema.Number,
  cpu: Schema.Struct({
    model: Schema.optional(Schema.String),
    cores: Schema.Number,
    usedPercent: Schema.optional(Schema.Number),
    history: Schema.Array(MachineLoadSample)
  }),
  gpu: Schema.optional(
    Schema.Struct({
      model: Schema.optional(Schema.String),
      cores: Schema.optional(Schema.Number),
      usedPercent: Schema.optional(Schema.Number),
      history: Schema.Array(MachineLoadSample)
    })
  ),
  memory: MachineStatsUsage,
  disk: Schema.optional(MachineStatsUsage)
})
export type MachineStats = typeof MachineStats.Type
