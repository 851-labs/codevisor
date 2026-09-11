import { Schema } from "effect"

export const ClientNavigationRequest = Schema.Struct({
  workspaceId: Schema.String,
  destination: Schema.optional(
    Schema.Struct({
      kind: Schema.Literals(["tab", "pane", "chat"]),
      id: Schema.String
    })
  )
})
export type ClientNavigationRequest = typeof ClientNavigationRequest.Type

export const ClientPaneContext = Schema.Struct({
  id: Schema.String,
  kind: Schema.String,
  title: Schema.String,
  sessionId: Schema.optional(Schema.String)
})
export const ClientTabContext = Schema.Struct({
  id: Schema.String,
  panes: Schema.Array(ClientPaneContext)
})
export const ClientWorkspaceContext = Schema.Struct({
  id: Schema.String,
  projectId: Schema.String,
  name: Schema.String,
  tabId: Schema.String,
  paneId: Schema.optional(Schema.String),
  sessionId: Schema.optional(Schema.String),
  tabs: Schema.Array(ClientTabContext)
})
/// A fresh view of one native window, restricted to this server's workspaces.
/// Omitted workspaceId means this window is on another page or machine.
export const ClientContext = Schema.Struct({
  isActive: Schema.Boolean,
  workspaceId: Schema.optional(Schema.String),
  workspaces: Schema.Array(ClientWorkspaceContext)
})
export type ClientContext = typeof ClientContext.Type

export const ConnectedClient = Schema.Struct({
  clientId: Schema.String,
  name: Schema.String,
  platform: Schema.Literals(["macos", "ios"])
})
export type ConnectedClient = typeof ConnectedClient.Type

export const ClientControlFrame = Schema.Union([
  Schema.Struct({
    type: Schema.Literal("hello"),
    name: Schema.String,
    platform: ConnectedClient.fields.platform
  }),
  Schema.Struct({
    type: Schema.Literal("response"),
    requestId: Schema.String,
    context: Schema.optional(ClientContext),
    error: Schema.optional(Schema.String)
  })
])

export interface ClientControlCommand {
  readonly requestId: string
  readonly method: "context" | "navigate"
  readonly navigation?: ClientNavigationRequest
}
