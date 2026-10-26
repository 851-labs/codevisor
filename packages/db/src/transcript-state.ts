import type Database from "better-sqlite3"

import { entryKeyRows, payloadRows } from "./common-rows.js"
import { jsonRecord, payloadMarkdown, payloadText, type JsonRecord } from "./event-payloads.js"
import { parseJsonObject } from "./json-column.js"
import type { SessionEventRow } from "./rows.js"
import { mergeTranscriptFields } from "./transcript-bodies.js"
import { appendTranscriptText } from "./transcript-text-state.js"

export {
  appendTranscriptText,
  readTranscriptText,
  textPatchForEvent,
  transcriptTextBlockSize
} from "./transcript-text-state.js"

const save = (
  db: Database.Database,
  event: SessionEventRow,
  itemId: string,
  key: string,
  category: string,
  parent: string,
  payload: JsonRecord
): void => {
  db.prepare(transcriptEntrySql.save).run(
    itemId,
    key,
    event.revision,
    event.revision,
    parent,
    category,
    payload.phase ?? null,
    JSON.stringify(payload)
  )
  const changes = Object.fromEntries(
    Object.entries(payload).filter(
      ([, value]) =>
        value !== undefined &&
        !(typeof value === "object" && value !== null && "transcriptBodyField" in value)
    )
  )
  if (Buffer.byteLength(JSON.stringify(changes)) > 32 * 1024) {
    const compact = mergeTranscriptFields(db, itemId, key, event.revision, payload, changes)
    db.prepare(transcriptEntrySql.setPayload).run(JSON.stringify(compact), itemId, key)
  }
}

const updateSessionState = (
  db: Database.Database,
  event: SessionEventRow,
  payload: JsonRecord
): void => {
  db.prepare(sessionSql.touchLastEvent).run(event.created_at, event.session_id)
  updateSessionGoal(db, event, payload)
  saveSessionConfigOptions(db, event, payload)
}

const updateSessionGoal = (
  db: Database.Database,
  event: SessionEventRow,
  payload: JsonRecord
): void => {
  if (event.kind === "session.updated") {
    if (payload.goalCleared === true || jsonRecord(payload.goal) !== undefined) {
      db.prepare(sessionSql.setGoalState).run(
        payload.goalCleared === true ? null : JSON.stringify(payload.goal),
        event.session_id
      )
    }
  }
}

const saveSessionConfigOptions = (
  db: Database.Database,
  event: SessionEventRow,
  payload: JsonRecord
): void => {
  if (event.kind === "session.updated" && Array.isArray(payload.configOptions)) {
    db.prepare(sessionStateSql.saveConfigOptions).run(
      event.session_id,
      event.revision,
      JSON.stringify({
        sessionUpdate: "config_option_update",
        configOptions: payload.configOptions
      })
    )
  }
}

const mergeSessionMetadata = (
  db: Database.Database,
  event: SessionEventRow,
  payload: JsonRecord,
  update: string | undefined
): void => {
  const key = update ?? event.kind
  const old = sessionStatePayload(db, event.session_id, key)
  db.prepare(sessionStateSql.save).run(
    event.session_id,
    key,
    event.revision,
    JSON.stringify({ ...(old === undefined ? {} : JSON.parse(old)), ...payload })
  )
}

const projectTranscriptText = (
  db: Database.Database,
  event: SessionEventRow,
  itemId: string,
  payload: JsonRecord,
  update: string | undefined,
  parent: string,
  messageId: string | undefined
): void => {
  const key = resolveTranscriptTextKey(db, event, itemId, parent, messageId, update)
  const prior = transcriptEntryPayload(db, itemId, key)
  const final = update === "assistant_message_finalized"
  const metadata = makeTranscriptTextMetadata(prior, payload, parent, messageId, final)
  save(db, event, itemId, key, "text", parent, metadata)
  appendTranscriptText(
    db,
    itemId,
    key,
    (final ? payloadMarkdown(payload) : payloadText(payload)) ?? "",
    final
  )
  upsertTranscriptTextHead(db, itemId, parent, key)
}

const resolveTranscriptTextKey = (
  db: Database.Database,
  event: SessionEventRow,
  itemId: string,
  parent: string,
  messageId: string | undefined,
  update: string | undefined
): string => {
  const head = transcriptHeadKey(db, itemId, parent)
  if (messageId !== undefined) return `message:${parent}:${messageId}`

  if (update === "assistant_message_finalized") {
    const priorAnswer = latestTranscriptAnswerKey(db, itemId, parent)
    if (priorAnswer !== undefined) return priorAnswer
  }

  return head?.startsWith("text:") ? head : `text:${event.revision}`
}

const makeTranscriptTextMetadata = (
  prior: string | undefined,
  payload: JsonRecord,
  parent: string,
  messageId: string | undefined,
  final: boolean
): JsonRecord => {
  const previousMetadata = prior === undefined ? {} : parseJsonObject(prior)
  return {
    ...previousMetadata,
    generation: Number(previousMetadata.generation ?? 0) + (final ? 1 : 0),
    sessionUpdate: "agent_message_chunk",
    ...(messageId === undefined ? {} : { messageId }),
    ...(parent === "" ? {} : { parentToolCallId: parent }),
    ...(payload.phase === undefined ? {} : { phase: payload.phase }),
    ...(final ? { phase: "final", attachments: payload.attachments } : {})
  }
}

const rewriteTranscriptText = (
  db: Database.Database,
  event: SessionEventRow,
  itemId: string | undefined,
  payload: JsonRecord
): void => {
  const { entryKey, markdown } = payload
  if (itemId === undefined || typeof entryKey !== "string" || typeof markdown !== "string") return
  const prior = transcriptEntryPayload(db, itemId, entryKey)
  if (prior === undefined) return

  const metadata = parseJsonObject(prior)
  const parent = typeof metadata.parentToolCallId === "string" ? metadata.parentToolCallId : ""
  const generation = Number(metadata.generation) + 1
  save(db, event, itemId, entryKey, "text", parent, { ...metadata, generation })
  appendTranscriptText(db, itemId, entryKey, markdown, true)
}

const upsertTranscriptTextHead = (
  db: Database.Database,
  itemId: string,
  parent: string,
  key: string
): void => {
  db.prepare(transcriptHeadSql.upsertText).run(itemId, parent, key)
}

const mergeTranscriptTool = (
  db: Database.Database,
  event: SessionEventRow,
  itemId: string,
  payload: JsonRecord,
  parent: string
): void => {
  if (typeof payload.toolCallId !== "string") return
  const key = `tool:${payload.toolCallId}`
  const previous = transcriptEntryPayload(db, itemId, key)
  if (previous === undefined) save(db, event, itemId, key, "tool", parent, {})
  const merged = mergeTranscriptFields(
    db,
    itemId,
    key,
    event.revision,
    previous === undefined ? {} : JSON.parse(previous),
    { ...payload, sessionUpdate: "tool_call" }
  )
  save(db, event, itemId, key, "tool", parent, merged)
}

const projectTranscriptCompaction = (
  db: Database.Database,
  event: SessionEventRow,
  itemId: string,
  payload: JsonRecord,
  parent: string
): void => {
  const key = `compaction:${typeof payload.compactionId === "string" ? payload.compactionId : "current"}`
  if (payload.status === "failed") {
    db.prepare(transcriptEntrySql.delete).run(itemId, key)
  } else {
    const previous = transcriptEntryPayload(db, itemId, key)
    save(db, event, itemId, key, "compaction", parent, {
      ...(previous === undefined ? {} : JSON.parse(previous)),
      ...payload
    })
  }
}

export const projectTranscriptState = (
  db: Database.Database,
  event: SessionEventRow,
  itemId: string | undefined,
  payload: JsonRecord = jsonRecord(JSON.parse(event.payload)) ?? {}
): void => {
  updateSessionState(db, event, payload)
  const update = typeof payload.sessionUpdate === "string" ? payload.sessionUpdate : undefined
  if (update === "assistant_text_rewritten") {
    rewriteTranscriptText(db, event, itemId, payload)
    return
  }
  if (itemId === undefined) {
    mergeSessionMetadata(db, event, payload, update)
    return
  }
  if (event.kind !== "session.output") return
  const parent = typeof payload.parentToolCallId === "string" ? payload.parentToolCallId : ""
  const messageId = typeof payload.messageId === "string" ? payload.messageId : undefined
  const isText =
    update === "agent_message_chunk" ||
    (payload.role === "assistant" && typeof payload.text === "string")
  if (isText || update === "assistant_message_finalized") {
    if (isText && !payloadText(payload) && messageId === undefined) return
    projectTranscriptText(db, event, itemId, payload, update, parent, messageId)
    return
  }
  db.prepare(transcriptHeadSql.delete).run(itemId, parent)
  if (update === "agent_thought_chunk") return
  if (update === "tool_call" || update === "tool_call_update") {
    mergeTranscriptTool(db, event, itemId, payload, parent)
  } else if (update === "plan_document" && typeof payload.markdown === "string") {
    save(db, event, itemId, "plan", "plan", parent, {
      ...payload,
      markdown: undefined
    })
    appendTranscriptText(db, itemId, "plan", payload.markdown, true)
  } else if (update === "context_compaction") {
    projectTranscriptCompaction(db, event, itemId, payload, parent)
  } else if (update === "question" || update === "question_resolved") {
    save(db, event, itemId, `${update}:${String(payload.questionId)}`, "question", parent, payload)
  } else if (update !== undefined) {
    save(db, event, itemId, update, update, parent, payload)
  }
}

const sessionStatePayload = (
  db: Database.Database,
  sessionId: string,
  key: string
): string | undefined =>
  payloadRows.maybe(db.prepare(sessionStateSql.payload).get(sessionId, key))?.payload

const transcriptHeadKey = (
  db: Database.Database,
  itemId: string,
  parent: string
): string | undefined =>
  entryKeyRows.maybe(db.prepare(transcriptHeadSql.entryKey).get(itemId, parent))?.entry_key

const latestTranscriptAnswerKey = (
  db: Database.Database,
  itemId: string,
  parent: string
): string | undefined =>
  entryKeyRows.maybe(db.prepare(transcriptEntrySql.latestAnswerKey).get(itemId, parent))?.entry_key

const transcriptEntryPayload = (
  db: Database.Database,
  itemId: string,
  key: string
): string | undefined =>
  payloadRows.maybe(db.prepare(transcriptEntrySql.payload).get(itemId, key))?.payload

const transcriptEntrySql = {
  save: `insert into transcript_entries
    (item_id, entry_key, position, revision, parent_id, category, phase, payload)
    values (?, ?, ?, ?, ?, ?, ?, ?)
    on conflict(item_id, entry_key) do update set revision = excluded.revision,
      phase = coalesce(excluded.phase, transcript_entries.phase), payload = excluded.payload`,
  setPayload: "update transcript_entries set payload = ? where item_id = ? and entry_key = ?",
  payload: "select payload from transcript_entries where item_id = ? and entry_key = ?",
  latestAnswerKey:
    "select entry_key from transcript_entries where item_id = ? and parent_id = ? and category = 'text' order by position desc limit 1",
  delete: "delete from transcript_entries where item_id = ? and entry_key = ?"
}

const transcriptHeadSql = {
  entryKey: "select entry_key from transcript_heads where item_id = ? and parent_id = ?",
  upsertText: `insert into transcript_heads (item_id, parent_id, entry_key, category) values (?, ?, ?, 'text')
      on conflict(item_id, parent_id) do update set entry_key = excluded.entry_key`,
  delete: "delete from transcript_heads where item_id = ? and parent_id = ?"
}

const sessionSql = {
  touchLastEvent:
    "update sessions set last_event_at = max(coalesce(last_event_at, ''), ?) where id = ?",
  setGoalState: "update sessions set goal_state = ? where id = ?"
}

const sessionStateSql = {
  payload: "select payload from session_state where session_id = ? and state_key = ?",
  save: `insert into session_state (session_id, state_key, revision, payload) values (?, ?, ?, ?)
      on conflict(session_id, state_key) do update set revision = excluded.revision, payload = excluded.payload`,
  saveConfigOptions: `insert into session_state(session_id, state_key, revision, payload) values (?, 'config_option_update', ?, ?)
      on conflict(session_id, state_key) do update set revision = excluded.revision, payload = excluded.payload`
}
