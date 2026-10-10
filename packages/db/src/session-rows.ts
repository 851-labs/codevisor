import type { SessionSidebarState, SessionSummary } from "@codevisor/api"

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
