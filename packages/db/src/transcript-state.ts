import type Database from "better-sqlite3"

import { jsonRecord, payloadText, type JsonRecord } from "./event-payloads.js"
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
  db.prepare(
    `insert into transcript_entries
    (item_id, entry_key, position, revision, parent_id, category, phase, payload)
    values (?, ?, ?, ?, ?, ?, ?, ?)
    on conflict(item_id, entry_key) do update set revision = excluded.revision,
      phase = coalesce(excluded.phase, transcript_entries.phase), payload = excluded.payload`
  ).run(
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
    db.prepare("update transcript_entries set payload = ? where item_id = ? and entry_key = ?").run(
      JSON.stringify(compact),
      itemId,
      key
    )
  }
}

const updateSessionState = (
  db: Database.Database,
  event: SessionEventRow,
  payload: JsonRecord
): void => {
  db.prepare(
    "update sessions set last_event_at = max(coalesce(last_event_at, ''), ?) where id = ?"
  ).run(event.created_at, event.session_id)
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
      db.prepare("update sessions set goal_state = ? where id = ?").run(
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
    db.prepare(
      `insert into session_state(session_id, state_key, revision, payload) values (?, 'config_option_update', ?, ?)
      on conflict(session_id, state_key) do update set revision = excluded.revision, payload = excluded.payload`
    ).run(
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
  // Metadata has its own current-state namespace; it never creates an empty turn.
  const key = update ?? event.kind
  const old = db
    .prepare("select payload from session_state where session_id = ? and state_key = ?")
    .get(event.session_id, key) as { payload: string } | undefined
  db.prepare(
    `insert into session_state (session_id, state_key, revision, payload) values (?, ?, ?, ?)
      on conflict(session_id, state_key) do update set revision = excluded.revision, payload = excluded.payload`
  ).run(
    event.session_id,
    key,
    event.revision,
    JSON.stringify({ ...(old ? JSON.parse(old.payload) : {}), ...payload })
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
  const prior = readTranscriptEntryPayload(db, itemId, key)
  const final = update === "assistant_message_finalized"
  const metadata = makeTranscriptTextMetadata(prior, payload, parent, messageId, final)
  save(db, event, itemId, key, "text", parent, metadata)
  appendTranscriptText(
    db,
    itemId,
    key,
    final ? String(payload.markdown ?? "") : (payloadText(payload) ?? ""),
    final
  )
  upsertTranscriptTextHead(db, itemId, parent, key)
}

const readTranscriptHead = (
  db: Database.Database,
  itemId: string,
  parent: string
): { entry_key: string } | undefined => {
  return db
    .prepare("select entry_key from transcript_heads where item_id = ? and parent_id = ?")
    .get(itemId, parent) as { entry_key: string } | undefined
}

const readLatestTranscriptAnswer = (
  db: Database.Database,
  itemId: string,
  parent: string
): { entry_key: string } | undefined => {
  return db
    .prepare(
      "select entry_key from transcript_entries where item_id = ? and parent_id = ? and category = 'text' order by position desc limit 1"
    )
    .get(itemId, parent) as { entry_key: string } | undefined
}

const resolveTranscriptTextKey = (
  db: Database.Database,
  event: SessionEventRow,
  itemId: string,
  parent: string,
  messageId: string | undefined,
  update: string | undefined
): string => {
  const head = readTranscriptHead(db, itemId, parent)
  const priorAnswer =
    update === "assistant_message_finalized" && messageId === undefined
      ? readLatestTranscriptAnswer(db, itemId, parent)
      : undefined
  return messageId === undefined
    ? (priorAnswer?.entry_key ??
        (head?.entry_key.startsWith("text:") ? head.entry_key : `text:${event.revision}`))
    : `message:${parent}:${messageId}`
}

const readTranscriptEntryPayload = (
  db: Database.Database,
  itemId: string,
  key: string
): { payload: string } | undefined => {
  return db
    .prepare("select payload from transcript_entries where item_id = ? and entry_key = ?")
    .get(itemId, key) as { payload: string } | undefined
}

const makeTranscriptTextMetadata = (
  prior: { payload: string } | undefined,
  payload: JsonRecord,
  parent: string,
  messageId: string | undefined,
  final: boolean
): JsonRecord => {
  const previousMetadata = prior === undefined ? {} : (JSON.parse(prior.payload) as JsonRecord)
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

const upsertTranscriptTextHead = (
  db: Database.Database,
  itemId: string,
  parent: string,
  key: string
): void => {
  db.prepare(
    `insert into transcript_heads (item_id, parent_id, entry_key, category) values (?, ?, ?, 'text')
      on conflict(item_id, parent_id) do update set entry_key = excluded.entry_key`
  ).run(itemId, parent, key)
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
  const previous = db
    .prepare("select payload from transcript_entries where item_id = ? and entry_key = ?")
    .get(itemId, key) as { payload: string } | undefined
  if (previous === undefined) save(db, event, itemId, key, "tool", parent, {})
  const merged = mergeTranscriptFields(
    db,
    itemId,
    key,
    event.revision,
    previous ? JSON.parse(previous.payload) : {},
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
  const key = `compaction:${payload.compactionId ?? "current"}`
  if (payload.status === "failed") {
    db.prepare("delete from transcript_entries where item_id = ? and entry_key = ?").run(
      itemId,
      key
    )
  } else {
    const previous = db
      .prepare("select payload from transcript_entries where item_id = ? and entry_key = ?")
      .get(itemId, key) as { payload: string } | undefined
    save(db, event, itemId, key, "compaction", parent, {
      ...(previous ? JSON.parse(previous.payload) : {}),
      ...payload
    })
  }
}

/** Fold provider updates into independently addressable transcript entities.
 * Called in the same transaction as the session revision and journal append. */
export const projectTranscriptState = (
  db: Database.Database,
  event: SessionEventRow,
  itemId: string | undefined,
  payload: JsonRecord = jsonRecord(JSON.parse(event.payload)) ?? {}
): void => {
  updateSessionState(db, event, payload)
  const update = typeof payload.sessionUpdate === "string" ? payload.sessionUpdate : undefined
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
  db.prepare("delete from transcript_heads where item_id = ? and parent_id = ?").run(itemId, parent)
  if (update === "agent_thought_chunk") return // Thinking is transient activity, not visible transcript text.
  if (update === "tool_call" || update === "tool_call_update") {
    mergeTranscriptTool(db, event, itemId, payload, parent)
  } else if (update === "plan_document" && typeof payload.markdown === "string") {
    save(db, event, itemId, "plan", "plan", parent, { ...payload, markdown: undefined })
    appendTranscriptText(db, itemId, "plan", payload.markdown, true)
  } else if (update === "context_compaction") {
    projectTranscriptCompaction(db, event, itemId, payload, parent)
  } else if (update === "question" || update === "question_resolved") {
    // Resolution is applied after the original question when hydrating a turn.
    save(db, event, itemId, `${update}:${payload.questionId}`, "question", parent, payload)
  } else if (update !== undefined) {
    save(db, event, itemId, update, update, parent, payload)
  }
}
