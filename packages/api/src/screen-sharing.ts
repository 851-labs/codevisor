import { Schema } from "effect"

export const ScreenSharingRequest = Schema.Struct({
  version: Schema.Literal(1),
  operation: Schema.Literals(["capabilities", "start", "restart", "heartbeat", "stop"]),
  workspaceId: Schema.String,
  paneId: Schema.String,
  viewerId: Schema.String,
  displayId: Schema.optional(Schema.String),
  offer: Schema.optional(Schema.String)
})
export type ScreenSharingRequest = typeof ScreenSharingRequest.Type

export const ScreenSharingReply = Schema.Struct({
  version: Schema.Literal(1),
  status: Schema.String,
  message: Schema.optional(Schema.String),
  /// How the display is streamed: WebRTC from the native helper (absent or
  /// "native") or RFB over the VNC socket route ("vnc").
  provider: Schema.optional(Schema.Literals(["native", "vnc"])),
  displays: Schema.Array(
    Schema.Struct({
      id: Schema.String,
      name: Schema.String,
      width: Schema.Number,
      height: Schema.Number
    })
  ),
  answer: Schema.optional(Schema.String),
  connectivity: Schema.optional(
    Schema.Struct({
      servers: Schema.Array(
        Schema.Struct({
          urls: Schema.Array(Schema.String),
          username: Schema.String,
          credential: Schema.String
        })
      ),
      relayOnly: Schema.Boolean,
      expiresAt: Schema.Number
    })
  )
})
export type ScreenSharingReply = typeof ScreenSharingReply.Type
