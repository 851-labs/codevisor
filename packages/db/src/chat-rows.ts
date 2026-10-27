import { integer, literal, nullable, optional, rowReader, text } from "./row-reader.js"

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
  readonly origin: string | null
  readonly attribution?: string | null
  readonly text: string
  readonly plan_document: string | null
}

export const conversationRows = rowReader<ConversationRow>({
  id: text,
  role: literal("user", "assistant", "system"),
  message_id: nullable(text),
  text,
  created_at: text,
  is_generating: integer,
  attachments: nullable(text)
})

export const transcriptRows = rowReader<TranscriptRow>({
  id: text,
  session_id: text,
  sequence: integer,
  role: literal("user", "assistant"),
  text,
  created_at: text,
  updated_at: text,
  is_generating: integer,
  has_details: integer,
  turn_id: nullable(text),
  started_at: nullable(text),
  ended_at: nullable(text),
  stop_reason: nullable(text),
  stop_detail: nullable(text),
  retryable: integer,
  plan_document: nullable(text),
  attachments: nullable(text),
  revision: integer
})

export const chatItemRows = rowReader<ChatItemRow>({
  id: text,
  session_id: text,
  position: integer,
  role: literal("user", "assistant", "system", "tool"),
  message_id: nullable(text),
  status: literal("streaming", "complete", "failed"),
  created_at: text,
  updated_at: text,
  turn_id: nullable(text),
  started_at: nullable(text),
  completed_at: nullable(text),
  plan_proposed_at: nullable(text),
  plan_resumed_at: nullable(text),
  stop_reason: nullable(text),
  stop_detail: nullable(text),
  stop_kind: nullable(text),
  retryable: integer,
  attachments: nullable(text),
  has_details: integer,
  revision: integer,
  origin: nullable(text),
  attribution: optional(nullable(text)),
  text,
  plan_document: nullable(text)
})
