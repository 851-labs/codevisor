import { Schema } from "effect"

/// Cloud protocol additions for the tunnel (docs/plans/codevisor-tunnel.md).
/// All optional or new frame types, so older peers are unaffected. Re-exported
/// through cloud-protocol.ts.

/// How to reach a machine's tunnel endpoint: its id plus the addresses it
/// last reported (home relay and direct `ip:port` candidates).
export const CloudTunnelInfo = Schema.Struct({
  endpointId: Schema.String,
  relayUrl: Schema.optional(Schema.String),
  directAddrs: Schema.Array(Schema.String)
})
export type CloudTunnelInfo = typeof CloudTunnelInfo.Type

/// One tunnel relay (`/.well-known/codevisor` and welcome). `quicPort` is the
/// relay's QUIC address-discovery port when it isn't the default 7842.
export const CloudRelayInfo = Schema.Struct({
  url: Schema.String,
  quicPort: Schema.optional(Schema.Number)
})
export type CloudRelayInfo = typeof CloudRelayInfo.Type

/// Per-connection tunnel switch in welcome. Clients only use the tunnel when
/// the hub says "on"; unknown values mean "off". The hub says "on" when the
/// device's `releaseChannel` is "alpha".
export const CloudTunnelRollout = Schema.Literals(["off", "on"])
export type CloudTunnelRollout = typeof CloudTunnelRollout.Type

/// The machine's tunnel endpoint address changed (new home relay, new
/// interfaces, a QAD-observed public address). The hub stores it and
/// republishes the machine's presence to apps.
export const MachineTunnelAddr = Schema.Struct({
  t: Schema.Literal("tunnel-addr"),
  tunnel: CloudTunnelInfo
})

/// The account's app devices the hub vouches for, with their static X25519
/// key and tunnel endpoint id. A machine's tunnel listener admits exactly
/// these (then pins them, TOFU): the hub is trusted for first contact only,
/// never for key continuity — the same trust the relay's attached
/// `peerPublicKey` carries today. Sent after welcome and on changes.
export const CloudVouchedDevice = Schema.Struct({
  deviceId: Schema.String,
  publicKey: Schema.String,
  endpointId: Schema.String
})
export type CloudVouchedDevice = typeof CloudVouchedDevice.Type

export const HubPeerDevices = Schema.Struct({
  t: Schema.Literal("peer-devices"),
  devices: Schema.Array(CloudVouchedDevice)
})
