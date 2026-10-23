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
  clientId: Schema.optional(Schema.String),
  botId: Schema.optional(Schema.String),
  botMachineId: Schema.optional(Schema.String)
})
export type MachineCallOrigin = typeof MachineCallOrigin.Type

export const FLEET_CALLER_HEADER = "x-codevisor-fleet-caller"
export const FLEET_SESSION_EVENT_PATH = "fleet.session_event"

export const isFleetPath = (path: string): boolean => path.startsWith("fleet.")
export const BOT_LINK_HEADER = "x-codevisor-bot-link"

export interface RemoteSessionRef {
  readonly machineId: string
  readonly sessionId: string
}

const REMOTE_SESSION_PREFIX = "remote:"
const NO_REMOTE_SESSION = "none"
const ESCAPED_NO_REMOTE_SESSION = "%6Eone"

export const remoteSessionKey = (machineId: string, sessionId: string | undefined): string =>
  `${REMOTE_SESSION_PREFIX}${encodeKeyPart(machineId)}:${encodeSessionPart(sessionId)}`

export const parseRemoteSessionKey = (key: string): RemoteSessionRef | undefined => {
  if (!key.startsWith(REMOTE_SESSION_PREFIX)) return undefined
  const parts = key.slice(REMOTE_SESSION_PREFIX.length).split(":")
  const sessionPart = parts.pop()!
  const machineId = legacyOrDecoded(parts)
  if (machineId === undefined || machineId === "") return undefined
  if (sessionPart === "" || sessionPart === NO_REMOTE_SESSION) return undefined
  const sessionId = decodeKeyPart(sessionPart)
  return sessionId === undefined ? undefined : { machineId, sessionId }
}

const encodeKeyPart = (value: string): string => encodeURIComponent(value)

const encodeSessionPart = (sessionId: string | undefined): string => {
  if (sessionId === undefined) return NO_REMOTE_SESSION
  if (sessionId === NO_REMOTE_SESSION) return ESCAPED_NO_REMOTE_SESSION
  return encodeKeyPart(sessionId)
}

const legacyOrDecoded = (machineParts: ReadonlyArray<string>): string | undefined => {
  if (machineParts.length === 1) return decodeKeyPart(machineParts[0]!)
  return machineParts.join(":")
}

const decodeKeyPart = (part: string): string | undefined => {
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
