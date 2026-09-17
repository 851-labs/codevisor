import type Database from "better-sqlite3"

import { jsonRecord, payloadText, type JsonRecord } from "./event-payloads.js"
import type { SessionEventRow } from "./rows.js"
import { mergeTranscriptFields, transcriptTextResource } from "./transcript-bodies.js"

// Small, appendable blocks keep streaming writes independent of answer length.
export const transcriptTextBlockSize = 8192
const prefix = (text: string, count: number): string => {
  const end = Math.min(count, text.length)
  const last = text.charCodeAt(end - 1)
  return text.slice(0, end < text.length && last >= 0xd800 && last <= 0xdbff ? end - 1 : end)
}

export const appendTranscriptText = (
  db: Database.Database,
  itemId: string,
  key: string,
  text: string,
  replace = false
): void => {
  if (replace)
    db.prepare("delete from transcript_text_chunks where item_id = ? and entry_key = ?").run(
      itemId,
      key
    )
  const last = db
    .prepare(
      "select position, text, char_offset from transcript_text_chunks where item_id = ? and entry_key = ? order by position desc limit 1"
    )
    .get(itemId, key) as { position: number; text: string; char_offset: number } | undefined
  let position = last?.position ?? 0
  const baseOffset = last === undefined ? 0 : last.char_offset + last.text.length
  let offset = 0
  if (last !== undefined && last.text.length < transcriptTextBlockSize) {
    const take = prefix(text, transcriptTextBlockSize - last.text.length)
    db.prepare(
      "update transcript_text_chunks set text = text || ? where item_id = ? and entry_key = ? and position = ?"
    ).run(take, itemId, key, position)
    offset = take.length
  }
  if (last !== undefined) position += 1
  const insert = db.prepare(
    "insert into transcript_text_chunks (item_id, entry_key, position, char_offset, text) values (?, ?, ?, ?, ?)"
  )
  while (offset < text.length) {
    const block = prefix(text.slice(offset), transcriptTextBlockSize)
    insert.run(itemId, key, position++, baseOffset + offset, block)
    offset += block.length
  }
  db.prepare(
    `update transcript_entries set text_length = ${replace ? "?" : "text_length + ?"} where item_id = ? and entry_key = ?`
  ).run(text.length, itemId, key)
}

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

/** Fold provider updates into independently addressable transcript entities.
 * Called in the same transaction as the session revision and journal append. */
export const projectTranscriptState = (
  db: Database.Database,
  event: SessionEventRow,
  itemId: string | undefined,
  payload: JsonRecord = jsonRecord(JSON.parse(event.payload)) ?? {}
): void => {
  db.prepare(
    "update sessions set last_event_at = max(coalesce(last_event_at, ''), ?) where id = ?"
  ).run(event.created_at, event.session_id)
  if (event.kind === "session.updated") {
    if (payload.goalCleared === true || jsonRecord(payload.goal) !== undefined) {
      db.prepare("update sessions set goal_state = ? where id = ?").run(
        payload.goalCleared === true ? null : JSON.stringify(payload.goal),
        event.session_id
      )
    }
  }
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
  const update = typeof payload.sessionUpdate === "string" ? payload.sessionUpdate : undefined
  if (itemId === undefined) {
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
    const head = db
      .prepare("select entry_key from transcript_heads where item_id = ? and parent_id = ?")
      .get(itemId, parent) as { entry_key: string } | undefined
    const priorAnswer =
      update === "assistant_message_finalized" && messageId === undefined
        ? (db
            .prepare(
              "select entry_key from transcript_entries where item_id = ? and parent_id = ? and category = 'text' order by position desc limit 1"
            )
            .get(itemId, parent) as { entry_key: string } | undefined)
        : undefined
    const key =
      messageId === undefined
        ? (priorAnswer?.entry_key ??
          (head?.entry_key.startsWith("text:") ? head.entry_key : `text:${event.revision}`))
        : `message:${parent}:${messageId}`
    const prior = db
      .prepare("select payload from transcript_entries where item_id = ? and entry_key = ?")
      .get(itemId, key) as { payload: string } | undefined
    const final = update === "assistant_message_finalized"
    const previousMetadata = prior === undefined ? {} : (JSON.parse(prior.payload) as JsonRecord)
    const metadata: JsonRecord = {
      ...previousMetadata,
      generation: Number(previousMetadata.generation ?? 0) + (final ? 1 : 0),
      sessionUpdate: "agent_message_chunk",
      ...(messageId === undefined ? {} : { messageId }),
      ...(parent === "" ? {} : { parentToolCallId: parent }),
      ...(payload.phase === undefined ? {} : { phase: payload.phase }),
      ...(final ? { phase: "final", attachments: payload.attachments } : {})
    }
    save(db, event, itemId, key, "text", parent, metadata)
    appendTranscriptText(
      db,
      itemId,
      key,
      final ? String(payload.markdown ?? "") : (payloadText(payload) ?? ""),
      final
    )
    db.prepare(
      `insert into transcript_heads (item_id, parent_id, entry_key, category) values (?, ?, ?, 'text')
      on conflict(item_id, parent_id) do update set entry_key = excluded.entry_key`
    ).run(itemId, parent, key)
    return
  }
  db.prepare("delete from transcript_heads where item_id = ? and parent_id = ?").run(itemId, parent)
  if (update === "agent_thought_chunk") return // Thinking is transient activity, not visible transcript text.
  if (update === "tool_call" || update === "tool_call_update") {
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
  } else if (update === "plan_document" && typeof payload.markdown === "string") {
    save(db, event, itemId, "plan", "plan", parent, { ...payload, markdown: undefined })
    appendTranscriptText(db, itemId, "plan", payload.markdown, true)
  } else if (update === "context_compaction") {
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
  } else if (update === "question" || update === "question_resolved") {
    // Resolution is applied after the original question when hydrating a turn.
    save(db, event, itemId, `${update}:${payload.questionId}`, "question", parent, payload)
  } else if (update !== undefined) {
    save(db, event, itemId, update, update, parent, payload)
  }
}

export const readTranscriptText = (
  db: Database.Database,
  itemId: string,
  key: string,
  limit?: number
): string => {
  const blocks: string[] = []
  let remaining = limit ?? Number.MAX_SAFE_INTEGER
  for (const row of db
    .prepare(
      "select text from transcript_text_chunks where item_id = ? and entry_key = ? order by position"
    )
    .iterate(itemId, key)) {
    const text = prefix((row as { text: string }).text, remaining)
    blocks.push(text)
    remaining -= text.length
    if (remaining <= 0 || text.length < (row as { text: string }).text.length) break
  }
  return blocks.join("")
}

export const textPatchForEvent = (
  db: Database.Database,
  itemId: string,
  revision: number,
  payload: JsonRecord
): JsonRecord | undefined => {
  if (
    payload.sessionUpdate !== "agent_message_chunk" &&
    payload.sessionUpdate !== "assistant_message_finalized" &&
    payload.role !== "assistant"
  )
    return undefined
  const parent = typeof payload.parentToolCallId === "string" ? payload.parentToolCallId : ""
  const row = db
    .prepare(
      `select e.entry_key, e.payload, e.text_length, e.position from transcript_heads h
    join transcript_entries e on e.item_id = h.item_id and e.entry_key = h.entry_key
    where h.item_id = ? and h.parent_id = ? and e.revision = ?`
    )
    .get(itemId, parent, revision) as
    | { entry_key: string; payload: string; text_length: number; position: number }
    | undefined
  if (row === undefined) return undefined
  const metadata = JSON.parse(row.payload) as JsonRecord
  const final = payload.sessionUpdate === "assistant_message_finalized"
  const rawText = final ? String(payload.markdown ?? "") : (payloadText(payload) ?? "")
  const offset = final ? 0 : row.text_length - rawText.length
  // Bound each delivery, not the lifetime of the message. Ordinary deltas
  // continue streaming after 24K; oversized individual updates carry a resource.
  const text = prefix(rawText, 24_000)
  return {
    ...metadata,
    sessionUpdate: "agent_message_patch",
    messageId: metadata.messageId ?? row.entry_key,
    text,
    offset,
    detailResource: transcriptTextResource(db, itemId, row.entry_key),
    totalLength: row.text_length,
    generation: metadata.generation ?? 0,
    stateRevision: revision,
    statePosition: row.position,
    isFinalized: final,
    chatItemId: itemId
  }
}
