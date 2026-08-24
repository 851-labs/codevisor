import { Schema } from "effect"

/// Wire protocol for the cloud relay (apps/cloud). Both planes — app↔hub and
/// machine↔hub — speak JSON text frames over a WebSocket to the user's hub.
///
/// Design invariants (see docs/cloud.md):
/// - The hub is a dumb router: it understands hello/presence and rewrites
///   addressing on relay frames, but never parses channel payloads.
/// - Channel payloads are end-to-end encrypted between an app device and a
///   machine device. The hub relays ciphertext; even `channelType` lives
///   inside the sealed open payload.
/// - Channels are ephemeral (they die with either WebSocket); durable session
///   state (e.g. terminal replay) is reattached by the opener after reconnect.
export const CLOUD_PROTOCOL_VERSION = 1

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

// ---------------------------------------------------------------------------
// Sealed payloads (end-to-end encryption)
// ---------------------------------------------------------------------------

/// IETF ChaCha20-Poly1305 box (base64url). The per-channel key comes from the
/// dual-DH agreement in @codevisor/cloud-crypto; the nonce is deterministic
/// from (direction, seq) so it never travels on the wire, and the AAD binds
/// channelId, direction, and the frame's plaintext `seq` so ciphertext cannot
/// be replayed across channels, directions, or positions.
export const SealedPayload = Schema.Struct({
  box: Schema.String
})
export type SealedPayload = typeof SealedPayload.Type

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
// Relay frames (opaque to the hub apart from addressing)
// ---------------------------------------------------------------------------
//
// Addressing is asymmetric and rewritten by the hub:
// - Apps address machines by their stable `deviceId` (`machineId` field).
// - Machines see an opaque per-app-connection `peerId` assigned by the hub,
//   so a machine can answer the right app socket without learning anything
//   else about it. `peerId` values do not survive reconnects.

const relayCommon = {
  channelId: Schema.String,
  /// Monotonic per-(channel, direction) counter starting at 0; bound into the
  /// AAD of `sealed`. A gap or repeat is a protocol error → close channel.
  seq: Schema.Number
}

export const RelayOpen = Schema.Struct({
  t: Schema.Literal("open"),
  ...relayCommon,
  /// Opener's ephemeral X25519 public key (base64url) for the channel's key
  /// agreement. The sealed payload carries { channelType, params }.
  ephemeralKey: Schema.String,
  sealed: SealedPayload
})
export const RelayData = Schema.Struct({
  t: Schema.Literal("data"),
  ...relayCommon,
  sealed: SealedPayload
})
/// Flow control between peers; the hub relays it like data. `bytes` grants
/// the sender that much additional sealed-payload budget.
export const RelayCredit = Schema.Struct({
  t: Schema.Literal("credit"),
  ...relayCommon,
  bytes: Schema.Number
})
export const RelayClose = Schema.Struct({
  t: Schema.Literal("close"),
  ...relayCommon,
  reason: ChannelCloseReason
})

export const RelayFrame = Schema.Union([RelayOpen, RelayData, RelayCredit, RelayClose])
export type RelayFrame = typeof RelayFrame.Type

// ---------------------------------------------------------------------------
// App plane
// ---------------------------------------------------------------------------

export const AppHello = Schema.Struct({
  t: Schema.Literal("hello"),
  protocol: Schema.Number,
  device: CloudDeviceInfo
})

export const AppRelayToMachine = Schema.Struct({
  t: Schema.Literal("relay"),
  machineId: Schema.String,
  frame: RelayFrame
})

export const AppPing = Schema.Struct({ t: Schema.Literal("ping") })

export const AppToHub = Schema.Union([AppHello, AppRelayToMachine, AppPing])
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

export const HubRelayFromMachine = Schema.Struct({
  t: Schema.Literal("relay"),
  machineId: Schema.String,
  frame: RelayFrame
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

export const HubToApp = Schema.Union([
  HubWelcome,
  HubPresence,
  HubRelayFromMachine,
  HubMachineReset,
  HubError,
  HubPong
])
export type HubToApp = typeof HubToApp.Type

// ---------------------------------------------------------------------------
// Machine plane
// ---------------------------------------------------------------------------

export const MachineHello = Schema.Struct({
  t: Schema.Literal("hello"),
  protocol: Schema.Number,
  device: CloudDeviceInfo
})

export const MachineRelayToPeer = Schema.Struct({
  t: Schema.Literal("relay"),
  peerId: Schema.String,
  frame: RelayFrame
})

export const MachinePing = Schema.Struct({ t: Schema.Literal("ping") })

export const MachineToHub = Schema.Union([MachineHello, MachineRelayToPeer, MachinePing])
export type MachineToHub = typeof MachineToHub.Type

export const HubMachineWelcome = Schema.Struct({
  t: Schema.Literal("welcome"),
  protocol: Schema.Number,
  connectionId: Schema.String
})

export const HubRelayFromApp = Schema.Struct({
  t: Schema.Literal("relay"),
  peerId: Schema.String,
  /// The opener app device's static public key, attached by the hub to `open`
  /// relays so the machine can complete key agreement and (TOFU-)pin the app.
  peerPublicKey: Schema.optional(Schema.String),
  /// The opener app device's stable self-assigned device id, attached by the
  /// hub to `open` relays alongside `peerPublicKey`. This is the identity the
  /// machine pins `peerPublicKey` under: a key change for a known device id is
  /// refused, so a misbehaving hub cannot swap keys on an established pairing.
  /// (The hub can still mint fresh device ids — TOFU trusts first sight — but
  /// it can never impersonate a device the machine has already seen.)
  peerDeviceId: Schema.optional(Schema.String),
  frame: RelayFrame
})

/// Sent to a machine when an app connection vanishes so it can tear down that
/// peer's channels (and e.g. detach terminal sinks) without waiting on idle
/// timeouts.
export const HubPeerGone = Schema.Struct({
  t: Schema.Literal("peer-gone"),
  peerId: Schema.String
})

export const HubToMachine = Schema.Union([
  HubMachineWelcome,
  HubRelayFromApp,
  HubPeerGone,
  HubError,
  HubPong
])
export type HubToMachine = typeof HubToMachine.Type

// ---------------------------------------------------------------------------
// Channel types (inside sealed `open` payloads — invisible to the hub)
// ---------------------------------------------------------------------------

/// Decrypted content of RelayOpen.sealed. `params` is channel-type-specific;
/// terminal channels use TerminalChannelParams to reattach durable sessions.
export const ChannelOpenPayload = Schema.Struct({
  channelType: Schema.String,
  params: Schema.optional(Schema.Unknown)
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
// Codecs
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
