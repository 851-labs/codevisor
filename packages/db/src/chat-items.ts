import { randomUUID } from "node:crypto"

import type {
  AttachmentRef,
  MessagePhase,
  SessionGoal,
  TranscriptBodyResource
} from "@codevisor/api"
import {
  MessagePhase as MessagePhaseSchema,
  SessionGoal as SessionGoalSchema
} from "@codevisor/api"
import type Database from "better-sqlite3"
import { Schema } from "effect"

import { numberField, parseJsonRecord, stringField, type JsonRecord } from "./event-payloads.js"
import { serializeAttachments } from "./row-mappers.js"
import { integer, nullable, rowReader, text as textColumn } from "./row-reader.js"
import { transcriptTextResource } from "./transcript-bodies.js"
import { appendTranscriptText, readTranscriptText } from "./transcript-state.js"

const chatStateRows = rowReader({
  next_position: integer,
  current_item_id: nullable(textColumn)
})

const chatRouteRows = rowReader({ item_id: textColumn })

const goalStateRows = rowReader({ goal_state: nullable(textColumn) })

const isMessagePhase = Schema.is(MessagePhaseSchema)

export const chatState = (
  sqlite: Database.Database,
  sessionId: string
): { next_position: number; current_item_id: string | null } => {
  sqlite.prepare(chatStateSql.ensure).run(sessionId)
  return chatStateRows.one(sqlite.prepare(chatStateSql.bySession).get(sessionId))
}

export const upsertChatPart = (
  sqlite: Database.Database,
  itemId: string,
  kind: "text" | "plan",
  text: string
): void => {
  const position = kind === "text" ? 0 : 1
  sqlite.prepare(upsertChatPartSql).run(`${itemId}:${kind}`, itemId, position, kind, text)
}

export const createChatItem = (
  sqlite: Database.Database,
  sessionId: string,
  role: "user" | "assistant" | "system" | "tool",
  createdAt: string,
  options: {
    readonly id?: string
    readonly position?: number
    readonly text?: string
    readonly messageId?: string
    readonly planDocument?: string
    readonly status: "streaming" | "complete" | "failed"
    readonly turnId?: string
    readonly startedAt?: string
    readonly completedAt?: string
    readonly stopReason?: string
    readonly stopDetail?: string
    readonly retryable?: boolean
    readonly attachments?: ReadonlyArray<AttachmentRef>
    readonly hasDetails?: boolean
    readonly revision?: number
    readonly origin?: "event"
  }
): string => {
  const state = chatState(sqlite, sessionId)
  const id = options.id ?? randomUUID()
  const position = options.position ?? state.next_position
  insertChatItemRow(sqlite, sessionId, role, createdAt, options, id, position)
  seedChatItemText(sqlite, id, options)
  seedChatItemPlan(sqlite, id, options)
  advanceChatItemState(sqlite, sessionId, role, position, id, options)
  return id
}

type CreateChatItemOptions = Parameters<typeof createChatItem>[4]

const insertChatItemRow = (
  sqlite: Database.Database,
  sessionId: string,
  role: Parameters<typeof createChatItem>[2],
  createdAt: string,
  options: CreateChatItemOptions,
  id: string,
  position: number
): void => {
  sqlite
    .prepare(chatItemSql.insert)
    .run(
      id,
      sessionId,
      position,
      role,
      options.messageId ?? null,
      options.status,
      createdAt,
      options.completedAt ?? createdAt,
      options.turnId ?? null,
      options.startedAt ?? null,
      options.completedAt ?? null,
      options.stopReason ?? null,
      options.stopDetail ?? null,
      Number(options.retryable === true),
      serializeAttachments(options.attachments),
      options.hasDetails === true ? 1 : 0,
      options.revision ?? 1,
      options.origin ?? null
    )
}

const seedChatItemText = (
  sqlite: Database.Database,
  id: string,
  options: CreateChatItemOptions
): void => {
  if (options.text !== undefined) {
    const migrated = transcriptStateMigrated(sqlite)
    upsertChatPart(sqlite, id, "text", migrated ? options.text.slice(0, 24_000) : options.text)
    seedStandaloneText(sqlite, id, options.text, options.messageId)
  }
}

const seedChatItemPlan = (
  sqlite: Database.Database,
  id: string,
  options: CreateChatItemOptions
): void => {
  if (options.planDocument !== undefined) {
    const migrated = transcriptStateMigrated(sqlite)
    upsertChatPart(
      sqlite,
      id,
      "plan",
      migrated ? options.planDocument.slice(0, 24_000) : options.planDocument
    )
    sqlite.prepare(transcriptEntrySql.seedPlan).run(id)
    appendTranscriptText(sqlite, id, "plan", options.planDocument, true)
  }
}

const transcriptStateMigrated = (sqlite: Database.Database): boolean =>
  sqlite.prepare(transcriptStateMigratedSql).get() !== undefined

const advanceChatItemState = (
  sqlite: Database.Database,
  sessionId: string,
  role: Parameters<typeof createChatItem>[2],
  position: number,
  id: string,
  options: CreateChatItemOptions
): void => {
  sqlite.prepare(chatStateSql.advance).run(position + 1, role, options.status, id, sessionId)
}

export const setChatRoute = (
  sqlite: Database.Database,
  sessionId: string,
  key: string,
  itemId: string
): void => {
  sqlite.prepare(chatRouteSql.upsert).run(sessionId, key, itemId)
}

export const chatRoute = (
  sqlite: Database.Database,
  sessionId: string,
  key: string
): string | undefined =>
  chatRouteRows.maybe(sqlite.prepare(chatRouteSql.byKey).get(sessionId, key))?.item_id

export const ensureAssistantChatItem = (
  sqlite: Database.Database,
  sessionId: string,
  createdAt: string,
  turnId?: string
): string => {
  if (turnId !== undefined) {
    const routed = chatRoute(sqlite, sessionId, `turn:${turnId}`)
    if (routed !== undefined) return routed
  }
  const current = chatState(sqlite, sessionId).current_item_id
  if (current !== null) {
    if (turnId !== undefined) {
      const bound = bindTurnToChatItem(sqlite, current, turnId)
      if (bound) setChatRoute(sqlite, sessionId, `turn:${turnId}`, current)
    }
    return current
  }
  const id = createChatItem(sqlite, sessionId, "assistant", createdAt, {
    status: "streaming",
    ...(turnId === undefined ? {} : { turnId })
  })
  if (turnId !== undefined) setChatRoute(sqlite, sessionId, `turn:${turnId}`, id)
  return id
}

export const chatAssistantSummary = (
  sqlite: Database.Database,
  _sessionId: string,
  itemId: string
): {
  text: string
  planDocument?: string
  messageId?: string
  phase?: MessagePhase
  textGeneration?: number
  textRevision?: number
  textPosition?: number
  textResource?: TranscriptBodyResource | undefined
  planResource?: TranscriptBodyResource | undefined
} => {
  const row = readAssistantAnswerRow(sqlite, itemId)
  const payload = row === undefined ? undefined : parseJsonRecord(row.payload)
  const hasPlan = hasPlanEntry(sqlite, itemId)
  return {
    text: row === undefined ? "" : readTranscriptText(sqlite, itemId, row.entry_key, 24_000),
    ...readAssistantPlanPreview(sqlite, itemId, hasPlan),
    ...readAssistantAnswerMetadata(sqlite, itemId, row, payload),
    ...(isMessagePhase(row?.phase) ? { phase: row.phase } : {})
  }
}

const assistantAnswerRows = rowReader({
  entry_key: textColumn,
  payload: textColumn,
  phase: nullable(textColumn),
  revision: integer,
  position: integer
})

type AssistantAnswerRow = ReturnType<typeof assistantAnswerRows.one>

const readAssistantAnswerRow = (
  sqlite: Database.Database,
  itemId: string
): AssistantAnswerRow | undefined => {
  return assistantAnswerRows.maybe(sqlite.prepare(transcriptEntrySql.latestAnswer).get(itemId))
}

const readAssistantPlanPreview = (
  sqlite: Database.Database,
  itemId: string,
  hasPlan: boolean
): Pick<ReturnType<typeof chatAssistantSummary>, "planResource" | "planDocument"> => {
  if (!hasPlan) return {}
  return {
    planResource: transcriptTextResource(sqlite, itemId, "plan"),
    planDocument: readTranscriptText(sqlite, itemId, "plan", 24_000)
  }
}

const readAssistantAnswerMetadata = (
  sqlite: Database.Database,
  itemId: string,
  row: AssistantAnswerRow | undefined,
  payload: JsonRecord | undefined
): Pick<
  ReturnType<typeof chatAssistantSummary>,
  "textResource" | "messageId" | "textGeneration" | "textRevision" | "textPosition"
> => {
  return row === undefined
    ? {}
    : {
        textResource: transcriptTextResource(sqlite, itemId, row.entry_key),
        messageId: stringField(payload, "messageId") ?? row.entry_key,
        textGeneration: numberField(payload, "generation") ?? 0,
        textRevision: row.revision,
        textPosition: row.position
      }
}

export const sessionGoalSnapshot = (
  sqlite: Database.Database,
  sessionId: string
): SessionGoal | undefined => {
  const goal = sessionGoalJson(sqlite, sessionId)
  if (goal == null) return undefined
  return Schema.decodeUnknownSync(SessionGoalSchema)(JSON.parse(goal))
}

export const finishAssistantChatItem = (
  sqlite: Database.Database,
  sessionId: string,
  itemId: string,
  completedAt: string,
  stopReason?: string,
  stopDetail?: string,
  stopKind?: string,
  retryable = false,
  failed = false
): void => {
  const summary = chatAssistantSummary(sqlite, sessionId, itemId)
  upsertChatPart(sqlite, itemId, "text", summary.text)
  if (summary.planDocument !== undefined) {
    upsertChatPart(sqlite, itemId, "plan", summary.planDocument)
  }
  sqlite
    .prepare(chatItemSql.finish)
    .run(
      failed ? "failed" : "complete",
      completedAt,
      completedAt,
      stopReason ?? null,
      stopDetail ?? null,
      stopKind ?? null,
      retryable ? 1 : 0,
      itemId
    )
}

export const seedStandaloneText = (
  db: Database.Database,
  itemId: string,
  text: string,
  messageId?: string
): void => {
  if (text.length === 0) return
  const key = messageId === undefined ? "imported-text" : `message::${messageId}`
  const inserted = insertStandaloneTextEntry(db, itemId, key, messageId)
  if (inserted) appendTranscriptText(db, itemId, key, text)
}

const insertStandaloneTextEntry = (
  db: Database.Database,
  itemId: string,
  key: string,
  messageId: string | undefined
): boolean =>
  db.prepare(transcriptEntrySql.seedText).run(
    itemId,
    key,
    JSON.stringify({
      sessionUpdate: "agent_message_chunk",
      messageId: messageId ?? key,
      generation: 0
    })
  ).changes > 0

const bindTurnToChatItem = (sqlite: Database.Database, itemId: string, turnId: string): boolean =>
  sqlite.prepare(chatItemSql.bindTurn).run(turnId, itemId).changes > 0

const hasPlanEntry = (sqlite: Database.Database, itemId: string): boolean =>
  sqlite.prepare(transcriptEntrySql.plan).get(itemId) !== undefined

const sessionGoalJson = (sqlite: Database.Database, sessionId: string): string | null | undefined =>
  goalStateRows.maybe(sqlite.prepare(goalStateSql).get(sessionId))?.goal_state

const chatStateSql = {
  ensure: `insert into session_chat_state (session_id, next_position, current_item_id)
       values (?, 0, null) on conflict(session_id) do nothing`,
  bySession: "select next_position, current_item_id from session_chat_state where session_id = ?",
  advance: `update session_chat_state set
         next_position = max(next_position, ?),
         current_item_id = case when ? = 'assistant' and ? = 'streaming' then ? else current_item_id end
       where session_id = ?`
}

const chatItemSql = {
  insert: `insert into chat_items (
        id, session_id, position, role, message_id, status, created_at, updated_at, turn_id,
        started_at, completed_at, stop_reason, stop_detail, retryable, attachments, has_details, revision,
        origin
      ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      on conflict(id) do nothing`,
  bindTurn: "update chat_items set turn_id = ? where id = ? and turn_id is null",
  finish: `update chat_items set status = ?,
       completed_at = case when status = 'complete' and completed_at is not null then completed_at else ? end,
       updated_at = ?,
       stop_reason = coalesce(?, stop_reason), stop_detail = coalesce(?, stop_detail),
       stop_kind = coalesce(?, stop_kind),
       retryable = ?,
       revision = revision + 1 where id = ?`
}

const upsertChatPartSql = `insert into chat_parts (id, item_id, position, kind, text, data_json, revision)
       values (?, ?, ?, ?, ?, null, 1)
       on conflict(item_id, position) do update set
         kind = excluded.kind, text = excluded.text, revision = chat_parts.revision + 1`

const chatRouteSql = {
  upsert: `insert into chat_item_routes (session_id, route_key, item_id) values (?, ?, ?)
       on conflict(session_id, route_key) do update set item_id = excluded.item_id`,
  byKey: "select item_id from chat_item_routes where session_id = ? and route_key = ?"
}

const transcriptEntrySql = {
  seedPlan: `insert into transcript_entries(item_id, entry_key, position, revision, category, payload)
      values (?, 'plan', 1, 0, 'plan', '{"sessionUpdate":"plan_document"}') on conflict do nothing`,
  seedText: `insert into transcript_entries (item_id, entry_key, position, revision, category, payload)
    values (?, ?, 0, 0, 'text', ?) on conflict(item_id, entry_key) do nothing`,
  plan: "select 1 from transcript_entries where item_id = ? and entry_key = 'plan'",
  latestAnswer: `select entry_key, payload, phase, revision, position from transcript_entries
    where item_id = ? and parent_id = '' and category = 'text' and text_length > 0
      and coalesce(phase, '') != 'commentary'
    order by position desc limit 1`
}

const transcriptStateMigratedSql =
  "select 1 from backfill_jobs where id = 'persisted-transcript-state-v1' and state = 'completed'"

const goalStateSql = "select goal_state from sessions where id = ?"
