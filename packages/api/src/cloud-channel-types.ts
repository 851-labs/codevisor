import { Schema } from "effect"

export const ChannelOpenPayload = Schema.Struct({
  channelType: Schema.String,
  params: Schema.optional(Schema.Unknown),
  compress: Schema.optional(Schema.Boolean),
  flowControl: Schema.optional(Schema.Boolean)
})
export type ChannelOpenPayload = typeof ChannelOpenPayload.Type

export const GATEWAY_CHANNEL_TYPE = "gateway"
