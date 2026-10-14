import { Schema } from "effect"

import {
  ClientCapabilities,
  ClientPageContext,
  ClientSplitContext,
  ClientWindowContext,
  type ClientPageRequest,
  type ClientLayoutRequest,
  type ClientWindowRequest
} from "./client-ui.js"

export const ClientNavigationRequest = Schema.Struct({
  workspaceId: Schema.String,
  destination: Schema.optional(
    Schema.Struct({
      kind: Schema.Literals(["tab", "pane", "chat", "leaf"]),
      id: Schema.String
    })
  )
})
export type ClientNavigationRequest = typeof ClientNavigationRequest.Type

export const ClientPaneContext = Schema.Struct({
  id: Schema.String,
  kind: Schema.String,
  title: Schema.String,
  sessionId: Schema.optional(Schema.String),
  leafId: Schema.optional(Schema.String)
})
export const ClientTabContext = Schema.Struct({
  id: Schema.String,
  panes: Schema.Array(ClientPaneContext),
  title: Schema.optional(Schema.String),
  activeLeafId: Schema.optional(Schema.String),
  splits: Schema.optional(Schema.Array(ClientSplitContext))
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
export const ClientContext = Schema.Struct({
  isActive: Schema.Boolean,
  workspaceId: Schema.optional(Schema.String),
  workspaces: Schema.Array(ClientWorkspaceContext),
  page: Schema.optional(ClientPageContext),
  capabilities: Schema.optional(ClientCapabilities),
  window: Schema.optional(ClientWindowContext)
})
export type ClientContext = typeof ClientContext.Type

export const ConnectedClient = Schema.Struct({
  clientId: Schema.String,
  name: Schema.String,
  platform: Schema.Literals(["macos", "ios"])
})
export type ConnectedClient = typeof ConnectedClient.Type

export const ClientViewing = Schema.Struct({
  workspaceId: Schema.optional(Schema.String),
  sessionId: Schema.optional(Schema.String),
  page: Schema.optional(Schema.String),
  panes: Schema.optional(Schema.Array(ClientPaneContext))
})
export type ClientViewing = typeof ClientViewing.Type

export const ClientSummary = Schema.Struct({
  id: Schema.String,
  clientId: Schema.String,
  name: Schema.String,
  platform: ConnectedClient.fields.platform,
  machine: Schema.Struct({ id: Schema.String, name: Schema.String }),
  online: Schema.Boolean,
  isOrigin: Schema.optional(Schema.Boolean),
  isActive: Schema.optional(Schema.Boolean),
  lastActiveAt: Schema.optional(Schema.String),
  viewing: Schema.optional(ClientViewing),
  capabilities: Schema.optional(ClientCapabilities)
})
export type ClientSummary = typeof ClientSummary.Type

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
  readonly method: "context" | "navigate" | "page" | "layout" | "window"
  readonly navigation?: ClientNavigationRequest
  readonly page?: ClientPageRequest
  readonly layout?: ClientLayoutRequest
  readonly window?: ClientWindowRequest
}
