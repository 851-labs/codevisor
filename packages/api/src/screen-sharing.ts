import { Schema } from "effect"

import { CloudTunnelInfo } from "./cloud-tunnel-protocol.js"

export const ScreenSharingMediaAddress = CloudTunnelInfo
export type ScreenSharingMediaAddress = CloudTunnelInfo

export const ScreenSharingRequest = Schema.Struct({
  version: Schema.Literal(1),
  operation: Schema.Literals(["capabilities", "start", "restart", "heartbeat", "stop", "setScale"]),
  workspaceId: Schema.String,
  paneId: Schema.String,
  viewerId: Schema.String,
  displayId: Schema.optional(Schema.String),
  scale: Schema.optional(Schema.Literals([1, 2])),
  engine: Schema.optional(Schema.Literal("v2")),
  media: Schema.optional(ScreenSharingMediaAddress),
  chroma: Schema.optional(Schema.Literals(["444", "420"]))
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
  engines: Schema.optional(Schema.Array(Schema.String)),
  media: Schema.optional(
    Schema.Struct({ ...ScreenSharingMediaAddress.fields, token: Schema.String })
  )
})
export type ScreenSharingReply = typeof ScreenSharingReply.Type
