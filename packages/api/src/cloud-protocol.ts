import { Schema } from "effect"

/// Wire protocol for the cloud relay (apps/cloud). Both planes — app↔hub and
/// machine↔hub — speak over a WebSocket to the user's hub using two message
/// kinds:
///
/// - **Text frames** carry rare JSON control messages (hello/welcome,
///   presence, ping/pong, errors) validated by the schemas below.
/// - **Binary frames** carry relay traffic: one or more envelopes, each a
///   small JSON header plus the raw ciphertext payload. No base64, no JSON
///   escaping of bulk bytes — see `encodeRelayEnvelopes`.
///
/// Design invariants (see docs/cloud.md):
/// - The hub is a dumb router: it understands hello/presence and rewrites
///   addressing on relay envelope headers, but never parses payloads —
///   content is end-to-end encrypted between devices and never readable
///   there. Even `channelType` lives inside the sealed open payload.
/// - Channels are ephemeral (they die with either WebSocket); durable session
///   state (e.g. terminal replay) is reattached by the opener after reconnect.
export const CLOUD_PROTOCOL_VERSION = 2

/// Upper bound for one relay WebSocket message (all envelopes included):
/// far above coalesced terminal output, far below platform message limits.
export const MAX_RELAY_MESSAGE_BYTES = 2 * 1024 * 1024

// ---------------------------------------------------------------------------
// Identity & presence
// ---------------------------------------------------------------------------

export const CloudDeviceKind = Schema.Literals(["app", "machine"])
export type CloudDeviceKind = typeof CloudDeviceKind.Type

/// Public identity a device presents in `hello` and the hub redistributes in
/// presence. `publicKey` is the device's static X25519 key (base64url); peers
/// pin it on first use (TOFU) — the hub is not trusted for key continuity.
export const CloudDeviceInfo = Schema.Struct({
  deviceId: Schema.String,
  kind: CloudDeviceKind,
  name: Schema.String,
  os: Schema.optional(Schema.String),
  appVersion: Schema.optional(Schema.String),
  publicKey: Schema.String
})
export type CloudDeviceInfo = typeof CloudDeviceInfo.Type

export const CloudMachinePresence = Schema.Struct({
  deviceId: Schema.String,
  name: Schema.String,
  os: Schema.optional(Schema.String),
  appVersion: Schema.optional(Schema.String),
  publicKey: Schema.String,
  online: Schema.Boolean,
  /// ISO timestamp of the last connect/disconnect the hub observed.
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

// ---------------------------------------------------------------------------
// Relay envelopes (binary; opaque to the hub apart from header addressing)
// ---------------------------------------------------------------------------
//
// A binary WebSocket message is a concatenation of one or more envelopes —
// senders may coalesce several relay frames into one message (cheaper for
// radios and for the hub's per-message billing); receivers process them in
// order. Each envelope is:
//
//   u32 BE header length | header JSON (UTF-8) | u32 BE payload length | payload
//
// The header is the addressing + frame metadata (`sealed` ciphertext never
// appears in JSON — it IS the payload):
// - open:   payload = ciphertext of the sealed { channelType, params }
// - data:   payload = ciphertext
// - credit: payload empty (`bytes` in the header)
// - close:  payload empty (`reason` in the header)
//
// Addressing is asymmetric and rewritten by the hub:
// - Apps address machines by their stable `deviceId` (`machineId` field).
// - Machines see an opaque per-app-connection `peerId` assigned by the hub,
//   so a machine can answer the right app socket without learning anything
//   else about it. `peerId` values do not survive reconnects.
//
// Headers are validated manually (not via Schema): they are the relay's hot
// path, and the hub forwards the original `frame` object untouched so future
// additive fields survive routing.

export type RelayFrameHeader =
  | {
      t: "open"
      channelId: string
      /// Monotonic per-(channel, direction) counter starting at 0; bound into
      /// the AAD of the payload. A gap or repeat is a protocol error → close.
      seq: number
      /// Opener's ephemeral X25519 public key (base64url) for the channel's
      /// key agreement.
      ephemeralKey: string
    }
  | { t: "data"; channelId: string; seq: number }
  /// Flow control between peers; the hub relays it like data. `bytes` grants
  /// the sender that much additional ciphertext-payload budget.
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
  /// The opener app device's static public key, attached by the hub to `open`
  /// relays so the machine can complete key agreement and (TOFU-)pin the app.
  peerPublicKey?: string
  /// The opener app device's stable self-assigned device id, attached by the
  /// hub to `open` relays alongside `peerPublicKey`. This is the identity the
  /// machine pins `peerPublicKey` under: a key change for a known device id is
  /// refused, so a misbehaving hub cannot swap keys on an established pairing.
  peerDeviceId?: string
  frame: RelayFrameHeader
}

export interface HubToAppRelayHeader {
  machineId: string
  frame: RelayFrameHeader
}

export interface WireRelayEnvelope {
  /// JSON-parsed header; validate with the parse helpers below.
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

/// Decodes a binary relay message into its envelopes. Throws on malformed
/// input; payloads are subarray views into the message (zero-copy).
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

/// Validates a relay frame header. Returns the ORIGINAL object (typed) so
/// routers can forward it with future additive fields intact.
export const parseRelayFrameHeader = (value: unknown): RelayFrameHeader | undefined => {
  if (typeof value !== "object" || value === null) return undefined
  const frame = value as Record<string, unknown>
  if (
    typeof frame.channelId !== "string" ||
    typeof frame.seq !== "number" ||
    !Number.isSafeInteger(frame.seq) ||
    frame.seq < 0
  ) {
    return undefined
  }
  switch (frame.t) {
    case "open":
      return typeof frame.ephemeralKey === "string" ? (value as RelayFrameHeader) : undefined
    case "data":
      return value as RelayFrameHeader
    case "credit":
      return typeof frame.bytes === "number" && Number.isSafeInteger(frame.bytes) && frame.bytes > 0
        ? (value as RelayFrameHeader)
        : undefined
    case "close":
      return typeof frame.reason === "string" && CLOSE_REASONS.has(frame.reason)
        ? (value as RelayFrameHeader)
        : undefined
    default:
      return undefined
  }
}

const parseAddressedHeader = <Header>(value: unknown, addressField: string): Header | undefined => {
  if (typeof value !== "object" || value === null) return undefined
  const header = value as Record<string, unknown>
  if (typeof header[addressField] !== "string") return undefined
  return parseRelayFrameHeader(header.frame) === undefined ? undefined : (value as Header)
}

export const parseAppRelayHeader = (value: unknown): AppRelayHeader | undefined =>
  parseAddressedHeader<AppRelayHeader>(value, "machineId")

export const parseMachineRelayHeader = (value: unknown): MachineRelayHeader | undefined =>
  parseAddressedHeader<MachineRelayHeader>(value, "peerId")

export const parseHubToMachineRelayHeader = (
  value: unknown
): HubToMachineRelayHeader | undefined => {
  const header = parseAddressedHeader<HubToMachineRelayHeader>(value, "peerId")
  if (header === undefined) return undefined
  if (header.peerPublicKey !== undefined && typeof header.peerPublicKey !== "string") {
    return undefined
  }
  if (header.peerDeviceId !== undefined && typeof header.peerDeviceId !== "string") {
    return undefined
  }
  return header
}

export const parseHubToAppRelayHeader = (value: unknown): HubToAppRelayHeader | undefined =>
  parseAddressedHeader<HubToAppRelayHeader>(value, "machineId")

// ---------------------------------------------------------------------------
// App plane (JSON text control frames)
// ---------------------------------------------------------------------------

export const AppHello = Schema.Struct({
  t: Schema.Literal("hello"),
  protocol: Schema.Number,
  device: CloudDeviceInfo
})

export const AppPing = Schema.Struct({ t: Schema.Literal("ping") })

export const AppToHub = Schema.Union([AppHello, AppPing])
export type AppToHub = typeof AppToHub.Type

export const HubWelcome = Schema.Struct({
  t: Schema.Literal("welcome"),
  protocol: Schema.Number,
  /// Hub-assigned id for this connection; also the peerId machines see.
  connectionId: Schema.String,
  machines: Schema.Array(CloudMachinePresence)
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
  /// Present when the error concerns a specific relay attempt.
  machineId: Schema.optional(Schema.String),
  channelId: Schema.optional(Schema.String)
})

export const HubPong = Schema.Struct({ t: Schema.Literal("pong") })

/// Sent to apps when a machine completes a (re)hello. Machine channel state
/// is in-memory and does not survive a socket replacement, so every channel
/// an app holds toward that machine is dead — even though the machine is
/// online. `presence` covers machines that visibly go offline; this covers
/// the reconnect race where the machine returns before (or without) its old
/// socket being seen to close. Apps predating this frame ignore unknown
/// kinds and fall back to presence/error-driven teardown.
export const HubMachineReset = Schema.Struct({
  t: Schema.Literal("machine-reset"),
  machineId: Schema.String
})

export const HubToApp = Schema.Union([HubWelcome, HubPresence, HubMachineReset, HubError, HubPong])
export type HubToApp = typeof HubToApp.Type

// ---------------------------------------------------------------------------
// Machine plane (JSON text control frames)
// ---------------------------------------------------------------------------

export const MachineHello = Schema.Struct({
  t: Schema.Literal("hello"),
  protocol: Schema.Number,
  device: CloudDeviceInfo
})

export const MachinePing = Schema.Struct({ t: Schema.Literal("ping") })

export const MachineToHub = Schema.Union([MachineHello, MachinePing])
export type MachineToHub = typeof MachineToHub.Type

export const HubMachineWelcome = Schema.Struct({
  t: Schema.Literal("welcome"),
  protocol: Schema.Number,
  connectionId: Schema.String
})

/// Sent to a machine when an app connection vanishes so it can tear down that
/// peer's channels (and e.g. detach terminal sinks) without waiting on idle
/// timeouts.
export const HubPeerGone = Schema.Struct({
  t: Schema.Literal("peer-gone"),
  peerId: Schema.String
})

export const HubToMachine = Schema.Union([HubMachineWelcome, HubPeerGone, HubError, HubPong])
export type HubToMachine = typeof HubToMachine.Type

// ---------------------------------------------------------------------------
// Channel types (inside sealed `open` payloads — invisible to the hub)
// ---------------------------------------------------------------------------

/// Decrypted content of an open envelope's payload. `params` is
/// channel-type-specific; terminal channels use TerminalChannelParams to
/// reattach durable sessions. `compress: true` negotiates prefix-framed
/// payloads: every data plaintext in both directions starts with a framing
/// byte (0 = raw, 1 = raw-DEFLATE body), letting the responder compress
/// compressible bodies. Invisible to the hub, like everything else here.
export const ChannelOpenPayload = Schema.Struct({
  channelType: Schema.String,
  params: Schema.optional(Schema.Unknown),
  compress: Schema.optional(Schema.Boolean)
})
export type ChannelOpenPayload = typeof ChannelOpenPayload.Type

export const TERMINAL_CHANNEL_TYPE = "terminal"

export const TerminalChannelParams = Schema.Struct({
  terminalId: Schema.String,
  /// Resume after this output sequence number (0 = from the start of the
  /// machine's retained frame window).
  sinceSeq: Schema.Number
})
export type TerminalChannelParams = typeof TerminalChannelParams.Type

// ---------------------------------------------------------------------------
// Codecs (JSON text control frames)
// ---------------------------------------------------------------------------

const decodeJson = <A, I>(schema: Schema.Codec<A, I>, raw: string): A =>
  Schema.decodeUnknownSync(schema)(JSON.parse(raw))

export const decodeAppToHub = (raw: string): AppToHub => decodeJson(AppToHub, raw)
export const decodeHubToApp = (raw: string): HubToApp => decodeJson(HubToApp, raw)
export const decodeMachineToHub = (raw: string): MachineToHub => decodeJson(MachineToHub, raw)
export const decodeHubToMachine = (raw: string): HubToMachine => decodeJson(HubToMachine, raw)

export const encodeCloudFrame = (
  frame: AppToHub | HubToApp | MachineToHub | HubToMachine
): string => JSON.stringify(frame)
