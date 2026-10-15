import type Database from "better-sqlite3"

import { payloadMarkdown, payloadText, type JsonRecord } from "./event-payloads.js"
import { parseJsonObject } from "./json-column.js"
import { integer, rowReader, text as textColumn } from "./row-reader.js"
import { transcriptTextResource } from "./transcript-bodies.js"

const lastChunkRows = rowReader({ position: integer, text: textColumn, char_offset: integer })

const chunkTextRows = rowReader({ text: textColumn })

const patchHeadRows = rowReader({
  entry_key: textColumn,
  payload: textColumn,
  text_length: integer,
  position: integer
})

type PatchHeadRow = ReturnType<typeof patchHeadRows.one>

export const transcriptTextBlockSize = 8192
const prefix = (text: string, count: number): string => {
  const end = Math.min(count, text.length)
  const last = text.charCodeAt(end - 1)
  return text.slice(0, end < text.length && last >= 0xd800 && last <= 0xdbff ? end - 1 : end)
}

const readLastTranscriptChunk = (db: Database.Database, itemId: string, key: string) => {
  return lastChunkRows.maybe(
    db
      .prepare(
        "select position, text, char_offset from transcript_text_chunks where item_id = ? and entry_key = ? order by position desc limit 1"
      )
      .get(itemId, key)
  )
}

const extendTranscriptTail = (
  db: Database.Database,
  itemId: string,
  key: string,
  text: string,
  last: { position: number; text: string; char_offset: number }
): number => {
  const take = prefix(text, transcriptTextBlockSize - last.text.length)
  db.prepare(
    "update transcript_text_chunks set text = text || ? where item_id = ? and entry_key = ? and position = ?"
  ).run(take, itemId, key, last.position)
  return take.length
}

const appendRemainingTranscriptBlocks = (
  db: Database.Database,
  itemId: string,
  key: string,
  text: string,
  position: number,
  baseOffset: number,
  offset: number
): void => {
  const insert = db.prepare(
    "insert into transcript_text_chunks (item_id, entry_key, position, char_offset, text) values (?, ?, ?, ?, ?)"
  )
  while (offset < text.length) {
    const block = prefix(text.slice(offset), transcriptTextBlockSize)
    insert.run(itemId, key, position++, baseOffset + offset, block)
    offset += block.length
  }
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
  const last = readLastTranscriptChunk(db, itemId, key)
  let position = last?.position ?? 0
  const baseOffset = last === undefined ? 0 : last.char_offset + last.text.length
  let offset = 0
  if (last !== undefined && last.text.length < transcriptTextBlockSize) {
    offset = extendTranscriptTail(db, itemId, key, text, last)
  }
  if (last !== undefined) position += 1
  appendRemainingTranscriptBlocks(db, itemId, key, text, position, baseOffset, offset)
  db.prepare(
    `update transcript_entries set text_length = ${replace ? "?" : "text_length + ?"} where item_id = ? and entry_key = ?`
  ).run(text.length, itemId, key)
}

export const readTranscriptText = (
  db: Database.Database,
  itemId: string,
  key: string,
  limit?: number
): string => {
  const blocks: string[] = []
  let remaining = limit ?? Number.MAX_SAFE_INTEGER
  for (const raw of db
    .prepare(
      "select text from transcript_text_chunks where item_id = ? and entry_key = ? order by position"
    )
    .iterate(itemId, key)) {
    const row = chunkTextRows.one(raw)
    const text = prefix(row.text, remaining)
    blocks.push(text)
    remaining -= text.length
    if (remaining <= 0 || text.length < row.text.length) break
  }
  return blocks.join("")
}

const readTranscriptPatchHead = (
  db: Database.Database,
  itemId: string,
  parent: string,
  revision: number
) => {
  return patchHeadRows.maybe(
    db
      .prepare(
        `select e.entry_key, e.payload, e.text_length, e.position from transcript_heads h
    join transcript_entries e on e.item_id = h.item_id and e.entry_key = h.entry_key
    where h.item_id = ? and h.parent_id = ? and e.revision = ?`
      )
      .get(itemId, parent, revision)
  )
}

const makeTranscriptEventPatch = (
  db: Database.Database,
  itemId: string,
  revision: number,
  payload: JsonRecord,
  row: PatchHeadRow
): JsonRecord => {
  const metadata = parseJsonObject(row.payload)
  const final = payload.sessionUpdate === "assistant_message_finalized"
  const rawText = (final ? payloadMarkdown(payload) : payloadText(payload)) ?? ""
  const offset = final ? 0 : row.text_length - rawText.length
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
  const row = readTranscriptPatchHead(db, itemId, parent, revision)
  if (row === undefined) return undefined
  return makeTranscriptEventPatch(db, itemId, revision, payload, row)
}
