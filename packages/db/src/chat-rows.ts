export interface ConversationRow {
  readonly id: string
  readonly role: "user" | "assistant" | "system"
  readonly message_id: string | null
  readonly text: string
  readonly created_at: string
  readonly is_generating: number
  readonly attachments: string | null
}

export interface TranscriptRow {
  readonly id: string
  readonly session_id: string
  readonly sequence: number
  readonly role: "user" | "assistant"
  readonly text: string
  readonly created_at: string
  readonly updated_at: string
  readonly is_generating: number
  readonly has_details: number
  readonly turn_id: string | null
  readonly started_at: string | null
  readonly ended_at: string | null
  readonly stop_reason: string | null
  readonly stop_detail: string | null
  readonly retryable: number
  readonly plan_document: string | null
  readonly attachments: string | null
  readonly revision: number
}

export interface ChatItemRow {
  readonly id: string
  readonly session_id: string
  readonly position: number
  readonly role: "user" | "assistant" | "system" | "tool"
  readonly message_id: string | null
  readonly status: "streaming" | "complete" | "failed"
  readonly created_at: string
  readonly updated_at: string
  readonly turn_id: string | null
  readonly started_at: string | null
  readonly completed_at: string | null
  readonly plan_proposed_at: string | null
  readonly plan_resumed_at: string | null
  readonly stop_reason: string | null
  readonly stop_detail: string | null
  readonly stop_kind: string | null
  readonly retryable: number
  readonly attachments: string | null
  readonly has_details: number
  readonly revision: number
  /// Selected from the typed parts table by chat page queries.
  readonly text: string
  readonly plan_document: string | null
}
