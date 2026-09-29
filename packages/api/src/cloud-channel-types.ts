import { Schema } from "effect"

/// Channel types of the cloud protocol: what travels inside sealed `open`
/// payloads, invisible to the hub. Re-exported through cloud-protocol.ts.

/// Decrypted content of an open envelope's payload. `params` is
/// channel-type-specific. `compress: true` negotiates prefix-framed
/// payloads: every data plaintext in both directions starts with a framing
/// byte (0 = raw, 1 = raw-DEFLATE body), letting the responder compress
/// compressible bodies. Invisible to the hub, like everything else here.
export const ChannelOpenPayload = Schema.Struct({
  channelType: Schema.String,
  params: Schema.optional(Schema.Unknown),
  compress: Schema.optional(Schema.Boolean),
  /// The opener runs this channel with explicit credit-based flow control in
  /// BOTH directions: each sender may only put granted ciphertext bytes in
  /// flight, and grants replenish as the receiver actually consumes. Openers
  /// set this only for channel types whose handlers grant credit (http, ws,
  /// byte-stream) — a flow-controlled open to an unaware handler would wait
  /// for grants forever.
  flowControl: Schema.optional(Schema.Boolean)
})
export type ChannelOpenPayload = typeof ChannelOpenPayload.Type

/// Machine→machine request channel: one Codevisor gateway call per channel
/// (see @codevisor/cloud-client gateway-channel.ts). The only channel type a
/// machine accepts from another machine.
export const GATEWAY_CHANNEL_TYPE = "gateway"
