import { TerminalActivity } from "@codevisor/api"
import { Schema } from "effect"

import { integer, nullable, optional, rowReader, text } from "./row-reader.js"

export interface WorkspaceRow {
  readonly sidebar_position: string
  readonly sidebar_order_revision: number
  readonly id: string
  readonly server_id: string
  readonly project_id: string
  readonly name: string
  readonly has_custom_name: number
  readonly is_archived: number
  readonly archived_at: string | null
  readonly created_at: string
  readonly updated_at: string | null
  readonly labels?: string | null
  readonly main_session_id?: string | null
  readonly default_checkout_id?: string | null
  readonly checkout_path?: string | null
  readonly checkout_git_branch?: string | null
  readonly checkout_git_detached_head?: string | null
  readonly checkout_git_pull_request?: string | null
  readonly checkout_git_known?: number | null
}

export interface WorkspacePaneRow {
  readonly id: string
  readonly workspace_id: string
  readonly provider_id: string
  readonly pane_type: string
  readonly title: string
  readonly resource_kind: string | null
  readonly resource_id: string | null
  readonly resource_server_id?: string | null
  readonly checkout_id?: string | null
  readonly metadata: string | null
  readonly live_title: string | null
  readonly terminal_activity: TerminalActivity | null
  readonly revision: number
  readonly position: string
  readonly created_at: string
  readonly updated_at: string | null
}

export const workspaceRows = rowReader<WorkspaceRow>({
  sidebar_position: text,
  sidebar_order_revision: integer,
  id: text,
  server_id: text,
  project_id: text,
  name: text,
  has_custom_name: integer,
  is_archived: integer,
  archived_at: nullable(text),
  created_at: text,
  updated_at: nullable(text),
  labels: optional(nullable(text)),
  main_session_id: optional(nullable(text)),
  default_checkout_id: optional(nullable(text)),
  checkout_path: optional(nullable(text)),
  checkout_git_branch: optional(nullable(text)),
  checkout_git_detached_head: optional(nullable(text)),
  checkout_git_pull_request: optional(nullable(text)),
  checkout_git_known: optional(nullable(integer))
})

export const workspacePaneRows = rowReader<WorkspacePaneRow>({
  id: text,
  workspace_id: text,
  provider_id: text,
  pane_type: text,
  title: text,
  resource_kind: nullable(text),
  resource_id: nullable(text),
  resource_server_id: optional(nullable(text)),
  checkout_id: optional(nullable(text)),
  metadata: nullable(text),
  live_title: nullable(text),
  terminal_activity: nullable(Schema.is(TerminalActivity)),
  revision: integer,
  position: text,
  created_at: text,
  updated_at: nullable(text)
})
