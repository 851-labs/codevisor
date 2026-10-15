import { EventKind } from "@codevisor/api"
import { Schema } from "effect"

import { integer, nullable, rowReader, text } from "./row-reader.js"

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

export const eventRows = rowReader<EventRow>({
  id: integer,
  server_id: text,
  kind: Schema.is(EventKind),
  subject_id: text,
  created_at: text,
  payload: text,
  transcript_item_id: nullable(text)
})

export const sessionEventRows = rowReader<SessionEventRow>({
  session_id: text,
  revision: integer,
  global_event_id: nullable(integer),
  server_id: text,
  kind: Schema.is(EventKind),
  created_at: text,
  payload: text,
  chat_item_id: nullable(text)
})
