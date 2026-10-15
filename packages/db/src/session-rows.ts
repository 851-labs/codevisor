import { SessionOrigin, SessionSidebarState, type SessionSummary } from "@codevisor/api"
import { Schema } from "effect"

import { integer, literal, nullable, optional, real, rowReader, text } from "./row-reader.js"

export interface SessionRow {
  readonly id: string
  readonly project_id: string
  readonly server_id: string
  readonly harness_id: string
  readonly harness_account_id: string | null
  readonly agent_session_id: string | null
  readonly title: string
  readonly title_is_user_set: number
  readonly origin: SessionSummary["origin"]
  readonly worktree_name: string | null
  readonly workspace_id: string | null
  readonly created_at: string
  readonly updated_at: string | null
  readonly sidebar_state: SessionSidebarState
  readonly sidebar_state_changed_at: string
  readonly usage_used: number | null
  readonly usage_size: number | null
  readonly input_tokens: number | null
  readonly cached_input_tokens: number | null
  readonly output_tokens: number | null
  readonly reasoning_output_tokens: number | null
  readonly total_tokens: number | null
  readonly cost_amount: number | null
  readonly cost_currency: string | null
  readonly cost_kind: "reported" | "estimated" | null
  readonly pending_question: string | null
  readonly background_tasks: string
  readonly session_plan: string | null
  readonly config_selections: string
  readonly unavailable_config_selections: string
  readonly attention_latest_sequence: number
  readonly attention_last_seen_sequence: number
  readonly attention_unread_count: number
  readonly attention_has_unread_error: number
  readonly attention_manually_unread: number
  readonly pending_plan_approval: number
  readonly parent_session_id?: string | null
  readonly labels?: string | null
}

export interface SessionActionRow {
  readonly session_id: string
  readonly client_action_id: string
  readonly action_kind: string
  readonly response: string
  readonly created_at: string
}

export interface PromptQueueRow {
  readonly id: string
  readonly session_id: string
  readonly text: string
  readonly created_at: string
  readonly updated_at: string
  readonly attachments: string | null
  readonly state: "pending" | "processing"
  readonly position: number
  readonly client_id?: string | null
}

export const sessionRows = rowReader<SessionRow>({
  id: text,
  project_id: text,
  server_id: text,
  harness_id: text,
  harness_account_id: nullable(text),
  agent_session_id: nullable(text),
  title: text,
  title_is_user_set: integer,
  origin: Schema.is(SessionOrigin),
  worktree_name: nullable(text),
  workspace_id: nullable(text),
  created_at: text,
  updated_at: nullable(text),
  sidebar_state: Schema.is(SessionSidebarState),
  sidebar_state_changed_at: text,
  usage_used: nullable(integer),
  usage_size: nullable(integer),
  input_tokens: nullable(integer),
  cached_input_tokens: nullable(integer),
  output_tokens: nullable(integer),
  reasoning_output_tokens: nullable(integer),
  total_tokens: nullable(integer),
  cost_amount: nullable(real),
  cost_currency: nullable(text),
  cost_kind: nullable(literal("reported", "estimated")),
  pending_question: nullable(text),
  background_tasks: text,
  session_plan: nullable(text),
  config_selections: text,
  unavailable_config_selections: text,
  attention_latest_sequence: integer,
  attention_last_seen_sequence: integer,
  attention_unread_count: integer,
  attention_has_unread_error: integer,
  attention_manually_unread: integer,
  pending_plan_approval: integer,
  parent_session_id: optional(nullable(text)),
  labels: optional(nullable(text))
})

export const sessionActionRows = rowReader<SessionActionRow>({
  session_id: text,
  client_action_id: text,
  action_kind: text,
  response: text,
  created_at: text
})

export const promptQueueRows = rowReader<PromptQueueRow>({
  id: text,
  session_id: text,
  text,
  created_at: text,
  updated_at: text,
  attachments: nullable(text),
  state: literal("pending", "processing"),
  position: integer,
  client_id: optional(nullable(text))
})
