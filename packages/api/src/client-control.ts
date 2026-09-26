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
/// A fresh view of one native window, restricted to this server's workspaces.
/// Omitted workspaceId means this window is on another page or machine.
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

/// What one window is showing right now, derived from its fresh context.
export const ClientViewing = Schema.Struct({
  workspaceId: Schema.optional(Schema.String),
  /// The chat selected in that workspace, when a chat is selected.
  sessionId: Schema.optional(Schema.String),
  /// The client page (for example "workspace", "home", or "settings").
  page: Schema.optional(Schema.String),
  /// Panes of the selected tab in the selected workspace.
  panes: Schema.optional(Schema.Array(ClientPaneContext))
})
export type ClientViewing = typeof ClientViewing.Type

/// One attached native window as listed by `GET /v1/clients`. `clientId`
/// duplicates `id` for consumers of the original listing shape. `viewing`
/// and `capabilities` are absent when the window did not answer a context
/// request in time; it is still attached and addressable.
export const ClientSummary = Schema.Struct({
  id: Schema.String,
  clientId: Schema.String,
  name: Schema.String,
  platform: ConnectedClient.fields.platform,
  machine: Schema.Struct({ id: Schema.String, name: Schema.String }),
  online: Schema.Boolean,
  /// Present only when the listing request named an origin client (the
  /// window that sent the prompt that started the calling agent's turn).
  isOrigin: Schema.optional(Schema.Boolean),
  /// Whether the window is the focused (key) window on its device.
  isActive: Schema.optional(Schema.Boolean),
  /// When this server last observed the window as the active window.
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
