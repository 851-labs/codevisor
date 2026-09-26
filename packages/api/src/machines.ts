import { Schema } from "effect"

/// One machine on the account as GET /v1/machines lists it: this server,
/// cloud-connected machines, and directly paired (FleetRoster) routes,
/// merged under one stable id (the machine's server id).
export const MachineSummary = Schema.Struct({
  id: Schema.String,
  name: Schema.String,
  os: Schema.optional(Schema.String),
  online: Schema.Boolean,
  /// ISO timestamp of the last time this machine was seen online.
  lastSeen: Schema.optional(Schema.String),
  /// Marks the machine that answered the request.
  isCurrent: Schema.Boolean
})
export type MachineSummary = typeof MachineSummary.Type

export const MachinesResponse = Schema.Struct({ machines: Schema.Array(MachineSummary) })
export type MachinesResponse = typeof MachinesResponse.Type

/// Who is making a cross-machine gateway call: the calling machine and,
/// when a chat made it, that chat and the native window that started its turn.
export const MachineCallOrigin = Schema.Struct({
  machineId: Schema.String,
  machineName: Schema.String,
  sessionId: Schema.optional(Schema.String),
  sessionTitle: Schema.optional(Schema.String),
  clientId: Schema.optional(Schema.String)
})
export type MachineCallOrigin = typeof MachineCallOrigin.Type

/// POST /v1/gateway/invoke: another machine's sandbox running one gateway
/// tool path (for example `browser.navigate`) on this machine.
export const GatewayInvokeRequest = Schema.Struct({
  path: Schema.String,
  args: Schema.optional(Schema.Unknown),
  origin: MachineCallOrigin
})
export type GatewayInvokeRequest = typeof GatewayInvokeRequest.Type

/// The tool's own result (null when it returned nothing). Failures answer
/// `{ error: { message, code?, details? } }` instead.
export const GatewayInvokeResponse = Schema.Struct({ result: Schema.Unknown })
export type GatewayInvokeResponse = typeof GatewayInvokeResponse.Type
