import type { EventKind } from "@codevisor/api"

export interface EventRow {
  readonly id: number
  readonly server_id: string
  readonly kind: EventKind
  readonly subject_id: string
  readonly created_at: string
  readonly payload: string
  readonly transcript_item_id: string | null
}

export interface SessionEventRow {
  readonly session_id: string
  readonly revision: number
  readonly global_event_id: number | null
  readonly server_id: string
  readonly kind: EventKind
  readonly created_at: string
  readonly payload: string
  readonly chat_item_id: string | null
}
