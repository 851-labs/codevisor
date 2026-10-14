import { Schema } from "effect"

export const CloudTunnelInfo = Schema.Struct({
  endpointId: Schema.String,
  relayUrl: Schema.optional(Schema.String),
  directAddrs: Schema.Array(Schema.String)
})
export type CloudTunnelInfo = typeof CloudTunnelInfo.Type

export const CloudRelayInfo = Schema.Struct({
  url: Schema.String,
  quicPort: Schema.optional(Schema.Number)
})
export type CloudRelayInfo = typeof CloudRelayInfo.Type

export const CloudTunnelRollout = Schema.Literals(["off", "on"])
export type CloudTunnelRollout = typeof CloudTunnelRollout.Type

export const MachineTunnelAddr = Schema.Struct({
  t: Schema.Literal("tunnel-addr"),
  tunnel: CloudTunnelInfo
})

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
