import { Schema } from "effect"

import {
  HubRoleHolders,
  HubRoleLease,
  MachineRoleMembership,
  MachineRoleRelease,
  MachineRoleRenew
} from "./cloud-role-protocol.js"
import {
  CloudRelayInfo,
  CloudTunnelInfo,
  HubPeerDevices,
  MachineTunnelAddr
} from "./cloud-tunnel-protocol.js"
import { isRecord } from "./records.js"
import { SandboxOrigin } from "./sandboxes.js"

export * from "./cloud-channel-types.js"
export * from "./cloud-tunnel-protocol.js"
export * from "./cloud-role-protocol.js"

export const CLOUD_PROTOCOL_VERSION = 2

export const MAX_RELAY_MESSAGE_BYTES = 2 * 1024 * 1024

export const CloudDeviceKind = Schema.Literals(["app", "machine"])
export type CloudDeviceKind = typeof CloudDeviceKind.Type

export const CloudDeviceInfo = Schema.Struct({
  deviceId: Schema.String,
  kind: CloudDeviceKind,
  name: Schema.String,
  os: Schema.optional(Schema.String),
  icon: Schema.optional(Schema.String),
  appVersion: Schema.optional(Schema.String),
  publicKey: Schema.String,
  serverId: Schema.optional(Schema.String),
  tunnelEndpointId: Schema.optional(Schema.String),
  releaseChannel: Schema.optional(Schema.Literals(["stable", "alpha"])),
  tunnelOnly: Schema.optional(Schema.Boolean)
})
export type CloudDeviceInfo = typeof CloudDeviceInfo.Type

export const CloudMachinePresence = Schema.Struct({
  deviceId: Schema.String,
  name: Schema.String,
  icon: Schema.optional(Schema.String),
  os: Schema.optional(Schema.String),
  appVersion: Schema.optional(Schema.String),
  publicKey: Schema.String,
  serverId: Schema.optional(Schema.String),
  machinePeers: Schema.optional(Schema.Boolean),
  tunnel: Schema.optional(CloudTunnelInfo),
  addedBy: Schema.optional(Schema.Struct({ deviceId: Schema.String, name: Schema.String })),
  ephemeral: Schema.optional(SandboxOrigin),
  online: Schema.Boolean,
  lastSeenAt: Schema.String
})
export type CloudMachinePresence = typeof CloudMachinePresence.Type

export const ChannelCloseReason = Schema.Literals([
  "done",
  "rejected",
  "unsupported",
  "peer-disconnected",
  "protocol-error",
  "crypto-error"
])
export type ChannelCloseReason = typeof ChannelCloseReason.Type

export type RelayFrameHeader =
  | {
      t: "open"
      channelId: string
      seq: number
      ephemeralKey: string
    }
  | { t: "data"; channelId: string; seq: number }
  | { t: "credit"; channelId: string; seq: number; bytes: number }
  | { t: "close"; channelId: string; seq: number; reason: ChannelCloseReason }

export interface AppRelayHeader {
  machineId: string
  frame: RelayFrameHeader
}

export interface MachineRelayHeader {
  peerId: string
  frame: RelayFrameHeader
}

export interface HubToMachineRelayHeader {
  peerId: string
  peerKind?: CloudDeviceKind
  peerPublicKey?: string
  peerDeviceId?: string
  frame: RelayFrameHeader
}

export interface HubToAppRelayHeader {
  machineId: string
  frame: RelayFrameHeader
}

export interface WireRelayEnvelope {
  header: unknown
  payload: Uint8Array
}

const textEncoder = new TextEncoder()
const textDecoder = new TextDecoder()

export const encodeRelayEnvelopes = (
  envelopes: ReadonlyArray<{ header: unknown; payload: Uint8Array }>
): Uint8Array => {
  const parts = envelopes.map((envelope) => ({
    headerBytes: textEncoder.encode(JSON.stringify(envelope.header)),
    payload: envelope.payload
  }))
  const total = parts.reduce(
    (sum, part) => sum + 8 + part.headerBytes.byteLength + part.payload.byteLength,
    0
  )
  const message = new Uint8Array(total)
  const view = new DataView(message.buffer)
  let offset = 0
  for (const part of parts) {
    view.setUint32(offset, part.headerBytes.byteLength)
    offset += 4
    message.set(part.headerBytes, offset)
    offset += part.headerBytes.byteLength
    view.setUint32(offset, part.payload.byteLength)
    offset += 4
    message.set(part.payload, offset)
    offset += part.payload.byteLength
  }
  return message
}

export const decodeRelayEnvelopes = (message: Uint8Array): WireRelayEnvelope[] => {
  const view = new DataView(message.buffer, message.byteOffset, message.byteLength)
  const envelopes: WireRelayEnvelope[] = []
  let offset = 0
  while (offset < message.byteLength) {
    if (message.byteLength - offset < 4) throw new Error("truncated envelope header length")
    const headerLength = view.getUint32(offset)
    offset += 4
    if (message.byteLength - offset < headerLength + 4) throw new Error("truncated envelope header")
    const header: unknown = JSON.parse(
      textDecoder.decode(message.subarray(offset, offset + headerLength))
    )
    offset += headerLength
    const payloadLength = view.getUint32(offset)
    offset += 4
    if (message.byteLength - offset < payloadLength) throw new Error("truncated envelope payload")
    envelopes.push({ header, payload: message.subarray(offset, offset + payloadLength) })
    offset += payloadLength
  }
  if (envelopes.length === 0) throw new Error("empty relay message")
  return envelopes
}

const CLOSE_REASONS: ReadonlySet<string> = new Set([
  "done",
  "rejected",
  "unsupported",
  "peer-disconnected",
  "protocol-error",
  "crypto-error"
])

const isRelayFrameHeader = (value: unknown): value is RelayFrameHeader => {
  if (
    !isRecord(value) ||
    typeof value.channelId !== "string" ||
    typeof value.seq !== "number" ||
    !Number.isSafeInteger(value.seq) ||
    value.seq < 0
  ) {
    return false
  }
  switch (value.t) {
    case "open":
      return typeof value.ephemeralKey === "string"
    case "data":
      return true
    case "credit":
      return typeof value.bytes === "number" && Number.isSafeInteger(value.bytes) && value.bytes > 0
    case "close":
      return typeof value.reason === "string" && CLOSE_REASONS.has(value.reason)
    default:
      return false
  }
}

export const parseRelayFrameHeader = (value: unknown): RelayFrameHeader | undefined =>
  isRelayFrameHeader(value) ? value : undefined

const isAddressedHeader = <Field extends string>(
  value: unknown,
  addressField: Field
): value is Record<string, unknown> & Record<Field, string> & { frame: RelayFrameHeader } =>
  isRecord(value) && typeof value[addressField] === "string" && isRelayFrameHeader(value.frame)

const isOptionalString = (value: unknown): value is string | undefined =>
  value === undefined || typeof value === "string"

const isHubToMachineRelayHeader = (value: unknown): value is HubToMachineRelayHeader =>
  isAddressedHeader(value, "peerId") &&
  isOptionalString(value.peerPublicKey) &&
  isOptionalString(value.peerDeviceId) &&
  (value.peerKind === undefined || value.peerKind === "app" || value.peerKind === "machine")

export const parseAppRelayHeader = (value: unknown): AppRelayHeader | undefined =>
  isAddressedHeader(value, "machineId") ? value : undefined

export const parseHubToMachineRelayHeader = (
  value: unknown
): HubToMachineRelayHeader | undefined => (isHubToMachineRelayHeader(value) ? value : undefined)

export const parseHubToAppRelayHeader = (value: unknown): HubToAppRelayHeader | undefined =>
  isAddressedHeader(value, "machineId") ? value : undefined

export type MachineOutboundRelayHeader =
  | ({ direction: "answer" } & MachineRelayHeader)
  | ({ direction: "open" } & AppRelayHeader)

export const parseMachineOutboundRelayHeader = (
  value: unknown
): MachineOutboundRelayHeader | undefined => {
  if (isAddressedHeader(value, "peerId")) return { ...value, direction: "answer" }
  const opened = parseAppRelayHeader(value)
  return opened === undefined ? undefined : { ...opened, direction: "open" }
}

export const AppHello = Schema.Struct({
  t: Schema.Literal("hello"),
  protocol: Schema.Number,
  device: CloudDeviceInfo,
  resume: Schema.optional(Schema.String)
})

export const AppPing = Schema.Struct({ t: Schema.Literal("ping") })

export const AppToHub = Schema.Union([AppHello, AppPing])
export type AppToHub = typeof AppToHub.Type

export const HubWelcome = Schema.Struct({
  t: Schema.Literal("welcome"),
  protocol: Schema.Number,
  connectionId: Schema.String,
  machines: Schema.Array(CloudMachinePresence),
  resume: Schema.optional(Schema.String),
  resumed: Schema.optional(Schema.Boolean),
  relays: Schema.optional(Schema.Array(CloudRelayInfo)),
  tunnel: Schema.optional(Schema.String)
})

export const HubPresence = Schema.Struct({
  t: Schema.Literal("presence"),
  machine: CloudMachinePresence
})

export const HubErrorCode = Schema.Literals([
  "unsupported-protocol",
  "machine-offline",
  "unknown-machine",
  "invalid-frame",
  "rate-limited"
])
export type HubErrorCode = typeof HubErrorCode.Type

export const HubError = Schema.Struct({
  t: Schema.Literal("error"),
  code: HubErrorCode,
  message: Schema.String,
  machineId: Schema.optional(Schema.String),
  channelId: Schema.optional(Schema.String)
})

export const HubPong = Schema.Struct({ t: Schema.Literal("pong") })

export const HubMachineReset = Schema.Struct({
  t: Schema.Literal("machine-reset"),
  machineId: Schema.String
})

export const HubToApp = Schema.Union([HubWelcome, HubPresence, HubMachineReset, HubError, HubPong])
export type HubToApp = typeof HubToApp.Type

export const MACHINE_PEERS_FEATURE = "machine-peers-v1"

export const MachineHello = Schema.Struct({
  t: Schema.Literal("hello"),
  protocol: Schema.Number,
  device: CloudDeviceInfo,
  resume: Schema.optional(Schema.String),
  features: Schema.optional(Schema.Array(Schema.String))
})

export const MachinePing = Schema.Struct({ t: Schema.Literal("ping") })

export const MachineInboxAck = Schema.Struct({
  t: Schema.Literal("inbox-ack"),
  itemIds: Schema.Array(Schema.String)
})

export const MachineToHub = Schema.Union([
  MachineHello,
  MachinePing,
  MachineTunnelAddr,
  MachineInboxAck,
  MachineRoleMembership,
  MachineRoleRenew,
  MachineRoleRelease
])
export type MachineToHub = typeof MachineToHub.Type

export const HubMachineWelcome = Schema.Struct({
  t: Schema.Literal("welcome"),
  protocol: Schema.Number,
  connectionId: Schema.String,
  resume: Schema.optional(Schema.String),
  resumed: Schema.optional(Schema.Boolean),
  machines: Schema.optional(Schema.Array(CloudMachinePresence)),
  relays: Schema.optional(Schema.Array(CloudRelayInfo)),
  tunnel: Schema.optional(Schema.String),
  features: Schema.optional(Schema.Array(Schema.String))
})

export const HubPeerGone = Schema.Struct({
  t: Schema.Literal("peer-gone"),
  peerId: Schema.String
})

export const HubInboxItem = Schema.Struct({
  t: Schema.Literal("inbox-item"),
  itemId: Schema.String,
  kind: Schema.Literals(["webhook", "oauth"]),
  sender: Schema.String,
  ephemeralKey: Schema.String,
  sealed: Schema.String
})
export type HubInboxItem = typeof HubInboxItem.Type

export const HubToMachine = Schema.Union([
  HubInboxItem,
  HubMachineWelcome,
  HubPeerGone,
  HubPresence,
  HubMachineReset,
  HubPeerDevices,
  HubRoleHolders,
  HubRoleLease,
  HubError,
  HubPong
])
export type HubToMachine = typeof HubToMachine.Type

const decodeJson = <A, I>(schema: Schema.Codec<A, I>, raw: string): A =>
  Schema.decodeUnknownSync(schema)(JSON.parse(raw))

export const decodeAppToHub = (raw: string): AppToHub => decodeJson(AppToHub, raw)
export const decodeHubToApp = (raw: string): HubToApp => decodeJson(HubToApp, raw)
export const decodeMachineToHub = (raw: string): MachineToHub => decodeJson(MachineToHub, raw)
export const decodeHubToMachine = (raw: string): HubToMachine => decodeJson(HubToMachine, raw)

export const encodeCloudFrame = (
  frame: AppToHub | HubToApp | MachineToHub | HubToMachine
): string => JSON.stringify(frame)
