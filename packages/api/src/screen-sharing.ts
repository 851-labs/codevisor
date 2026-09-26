import { Schema } from "effect"

export const ScreenSharingRequest = Schema.Struct({
  version: Schema.Literal(1),
  operation: Schema.Literals(["capabilities", "start", "restart", "heartbeat", "stop", "setScale"]),
  workspaceId: Schema.String,
  paneId: Schema.String,
  viewerId: Schema.String,
  displayId: Schema.optional(Schema.String),
  offer: Schema.optional(Schema.String),
  /// `setScale` (851-2339): the desktop's UI scale, 1× or 2× (a VNC desktop whose server can set it).
  scale: Schema.optional(Schema.Literals([1, 2])),
  /// Media over the Codevisor tunnel (docs/plans/codevisor-tunnel.md): the
  /// viewer's tunnel endpoint and the media flow it opened; the machine
  /// bridges that flow to the host WebRTC's socket.
  tunnelMedia: Schema.optional(Schema.Struct({ endpointId: Schema.String, flowId: Schema.Number }))
})
export type ScreenSharingRequest = typeof ScreenSharingRequest.Type

export const ScreenSharingReply = Schema.Struct({
  version: Schema.Literal(1),
  status: Schema.String,
  message: Schema.optional(Schema.String),
  /// How the display is streamed: WebRTC from the native helper (absent or
  /// "native") or RFB over the VNC socket route ("vnc").
  provider: Schema.optional(Schema.Literals(["native", "vnc"])),
  /// The VNC socket arbitrates control (text-frame lease messages, 851-2338).
  controlLease: Schema.optional(Schema.Boolean),
  displays: Schema.Array(
    Schema.Struct({
      id: Schema.String,
      name: Schema.String,
      width: Schema.Number,
      height: Schema.Number,
      /// UI scales `setScale` accepts for this display; absent when it can't be set (851-2339).
      scales: Schema.optional(Schema.Array(Schema.Number)),
      /// The size the desktop was provisioned at, for a viewer that stops resizing it.
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
  /// The request's tunnel flow is bridged: the viewer uses it as its only
  /// remote candidate and caps RTP packets at `maxPayload`.
  tunnelMedia: Schema.optional(
    Schema.Struct({ flowId: Schema.Number, maxPayload: Schema.optional(Schema.Number) })
  )
})
export type ScreenSharingReply = typeof ScreenSharingReply.Type
