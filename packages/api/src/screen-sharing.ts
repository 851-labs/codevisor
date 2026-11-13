import { Schema } from "effect"

import { CloudTunnelInfo } from "./cloud-tunnel-protocol.js"

export const ScreenSharingMediaAddress = CloudTunnelInfo
export type ScreenSharingMediaAddress = CloudTunnelInfo

export const ScreenSharingApp = Schema.Struct({
  key: Schema.String,
  name: Schema.String
})
export type ScreenSharingApp = typeof ScreenSharingApp.Type

export const ScreenSharingDisplay = Schema.Struct({
  id: Schema.String,
  name: Schema.String,
  width: Schema.Number,
  height: Schema.Number,
  scales: Schema.optional(Schema.Array(Schema.Number)),
  defaultWidth: Schema.optional(Schema.Number),
  defaultHeight: Schema.optional(Schema.Number)
})
export type ScreenSharingDisplay = typeof ScreenSharingDisplay.Type

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
  chroma: Schema.optional(Schema.Literals(["444", "420"])),
  app: Schema.optional(ScreenSharingApp),
  intent: Schema.optional(Schema.Literals(["open", "attach"]))
})
export type ScreenSharingRequest = typeof ScreenSharingRequest.Type

export const ScreenSharingReply = Schema.Struct({
  version: Schema.Literal(1),
  status: Schema.String,
  message: Schema.optional(Schema.String),
  provider: Schema.optional(Schema.Literals(["native", "vnc"])),
  controlLease: Schema.optional(Schema.Boolean),
  displays: Schema.Array(ScreenSharingDisplay),
  engines: Schema.optional(Schema.Array(Schema.String)),
  media: Schema.optional(
    Schema.Struct({ ...ScreenSharingMediaAddress.fields, token: Schema.String })
  ),
  abilities: Schema.optional(Schema.Array(Schema.String)),
  reason: Schema.optional(Schema.String),
  holderName: Schema.optional(Schema.String),
  display: Schema.optional(ScreenSharingDisplay)
})
export type ScreenSharingReply = typeof ScreenSharingReply.Type
