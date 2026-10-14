import { Schema } from "effect"

export const ScreenSharingRequest = Schema.Struct({
  version: Schema.Literal(1),
  operation: Schema.Literals(["capabilities", "start", "restart", "heartbeat", "stop", "setScale"]),
  workspaceId: Schema.String,
  paneId: Schema.String,
  viewerId: Schema.String,
  displayId: Schema.optional(Schema.String),
  offer: Schema.optional(Schema.String),
  scale: Schema.optional(Schema.Literals([1, 2])),
  tunnelMedia: Schema.optional(Schema.Struct({ endpointId: Schema.String, flowId: Schema.Number }))
})
export type ScreenSharingRequest = typeof ScreenSharingRequest.Type

export const ScreenSharingReply = Schema.Struct({
  version: Schema.Literal(1),
  status: Schema.String,
  message: Schema.optional(Schema.String),
  provider: Schema.optional(Schema.Literals(["native", "vnc"])),
  controlLease: Schema.optional(Schema.Boolean),
  displays: Schema.Array(
    Schema.Struct({
      id: Schema.String,
      name: Schema.String,
      width: Schema.Number,
      height: Schema.Number,
      scales: Schema.optional(Schema.Array(Schema.Number)),
      defaultWidth: Schema.optional(Schema.Number),
      defaultHeight: Schema.optional(Schema.Number)
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
  ),
  tunnelMedia: Schema.optional(
    Schema.Struct({ flowId: Schema.Number, maxPayload: Schema.optional(Schema.Number) })
  )
})
export type ScreenSharingReply = typeof ScreenSharingReply.Type
