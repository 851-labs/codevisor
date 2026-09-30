import { Schema } from "effect"

/// One machine on the account as GET /v1/machines lists it: this server and
/// its cloud-connected peers, under one stable id (the machine's server id).
export const MachineSummary = Schema.Struct({
  id: Schema.String,
  name: Schema.String,
  os: Schema.optional(Schema.String),
  online: Schema.Boolean,
  /// ISO timestamp of the last time this machine was seen online.
  lastSeen: Schema.optional(Schema.String),
  /// Marks the machine that answered the request.
  isCurrent: Schema.Boolean,
  /// The name of the machine whose invite added this one to the account
  /// (absent for machines a person added).
  addedBy: Schema.optional(Schema.String)
})
export type MachineSummary = typeof MachineSummary.Type

export const MachinesResponse = Schema.Struct({ machines: Schema.Array(MachineSummary) })
export type MachinesResponse = typeof MachinesResponse.Type

/// POST /v1/machines/invite: a one-time code that adds one new machine to
/// this machine's account without a human approval. Secret — anyone holding
/// it can add a machine until it expires (~10 minutes) or is used.
export const MachineInviteResponse = Schema.Struct({
  /// Run `codevisor auth login --invite -` on the new machine and pass the
  /// code on stdin, or set CODEVISOR_INVITE for the installer.
  code: Schema.String,
  expiresAt: Schema.String
})
export type MachineInviteResponse = typeof MachineInviteResponse.Type

/// POST /v1/machines/add: install Codevisor on a host over SSH (from this
/// machine, with its SSH keys and config) and add it to the account.
export const AddMachineRequest = Schema.Struct({
  /// SSH destination: `user@host`, `host`, or a Host alias from ~/.ssh/config.
  ssh: Schema.String,
  /// Display name for the new machine (defaults to its host name).
  name: Schema.optional(Schema.String),
  /// SSH port when not the default or set in ~/.ssh/config.
  sshPort: Schema.optional(Schema.Number)
})
export type AddMachineRequest = typeof AddMachineRequest.Type

export const AddMachineResponse = Schema.Struct({ machine: MachineSummary })
export type AddMachineResponse = typeof AddMachineResponse.Type

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
