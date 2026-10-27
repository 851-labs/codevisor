import { Schema } from "effect"

import { SandboxOrigin } from "./sandboxes.js"

export const MachineSummary = Schema.Struct({
  id: Schema.String,
  name: Schema.String,
  os: Schema.optional(Schema.String),
  online: Schema.Boolean,
  lastSeen: Schema.optional(Schema.String),
  isCurrent: Schema.Boolean,
  addedBy: Schema.optional(Schema.String),
  ephemeral: Schema.optional(SandboxOrigin)
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
  clientId: Schema.optional(Schema.String),
  botId: Schema.optional(Schema.String),
  botMachineId: Schema.optional(Schema.String)
})
export type MachineCallOrigin = typeof MachineCallOrigin.Type

export const FLEET_CALLER_HEADER = "x-codevisor-fleet-caller"
export const FLEET_SESSION_EVENT_PATH = "fleet.session_event"

export const isFleetPath = (path: string): boolean => path.startsWith("fleet.")
export const REMOTE_PARENT_HEADER = "x-codevisor-remote-parent"

export interface RemoteSessionRef {
  readonly machineId: string
  readonly sessionId: string
}

const REMOTE_SESSION_PREFIX = "remote2:"
const LEGACY_REMOTE_SESSION_PREFIX = "remote:"
const LEGACY_NO_REMOTE_SESSION = "none"

export const remoteSessionKey = (machineId: string, sessionId: string | undefined): string =>
  `${REMOTE_SESSION_PREFIX}${encodeURIComponent(machineId)}:${encodeURIComponent(sessionId ?? "")}`

export const parseRemoteSessionKey = (key: string): RemoteSessionRef | undefined => {
  if (key.startsWith(REMOTE_SESSION_PREFIX)) return parseEncoded(key)
  if (key.startsWith(LEGACY_REMOTE_SESSION_PREFIX)) return parseLegacy(key)
  return undefined
}

const parseEncoded = (key: string): RemoteSessionRef | undefined => {
  const parts = key.slice(REMOTE_SESSION_PREFIX.length).split(":")
  if (parts.length !== 2) return undefined
  return remoteRef(decodePart(parts[0]!), decodePart(parts[1]!))
}

const parseLegacy = (key: string): RemoteSessionRef | undefined => {
  const parts = key.slice(LEGACY_REMOTE_SESSION_PREFIX.length).split(":")
  const sessionId = parts.pop()!
  if (sessionId === LEGACY_NO_REMOTE_SESSION) return undefined
  return remoteRef(parts.join(":"), sessionId)
}

const remoteRef = (
  machineId: string | undefined,
  sessionId: string | undefined
): RemoteSessionRef | undefined => {
  if (machineId === undefined || machineId === "") return undefined
  if (sessionId === undefined || sessionId === "") return undefined
  return { machineId, sessionId }
}

const decodePart = (part: string): string | undefined => {
  try {
    return decodeURIComponent(part)
  } catch {
    return undefined
  }
}

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
