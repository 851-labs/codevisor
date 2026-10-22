import type { TranscriptBodyPage, TranscriptBodyResource } from "@codevisor/api"
import type Database from "better-sqlite3"

import type { JsonRecord } from "./event-payloads.js"
import { parseJsonObject, payloadGeneration } from "./json-column.js"
import { integer, literal, optional, rowReader, text } from "./row-reader.js"
import { readSetupBodyPage } from "./setup-state.js"

const blockSize = 8192

const bodyFieldRows = rowReader<TranscriptBodyResource["fields"][number]>({
  name: text,
  revision: integer,
  encoding: literal("text", "json"),
  sizeBytes: integer,
  pageCount: optional(integer),
  generation: optional(integer)
})

const toolSnapshotRows = rowReader({
  payload: text,
  revision: integer,
  position: integer
})

const textBodyMetadataRows = rowReader({ revision: integer, payload: text })

const bodyChunkRows = rowReader({ text, position: integer })

const fieldBodyMetadataRows = rowReader({
  revision: integer,
  encoding: literal("text", "json")
})

const textResourceRows = rowReader({
  revision: integer,
  text_length: integer,
  payload: text,
  page_count: integer
})

export const mergeTranscriptFields = (
  db: Database.Database,
  itemId: string,
  key: string,
  revision: number,
  previous: JsonRecord,
  changes: JsonRecord
): JsonRecord => {
  const payload = { ...previous }
  let inlineBytes = 0
  for (const [field, value] of Object.entries(changes)) {
    if (value === undefined) continue
    const encoded = typeof value === "string" ? value : JSON.stringify(value)
    const bytes = Buffer.byteLength(encoded)
    db.prepare(bodyChunkSql.deleteField).run(itemId, key, field)
    db.prepare(bodyFieldSql.delete).run(itemId, key, field)
    if (bytes <= 16 * 1024 && (inlineBytes + bytes <= 32 * 1024 || bytes < 512)) {
      payload[field] = value
      inlineBytes += bytes
      continue
    }
    db.prepare(bodyFieldSql.insert).run(
      itemId,
      key,
      field,
      revision,
      typeof value === "string" ? "text" : "json",
      bytes
    )
    writeTranscriptFieldChunks(db, itemId, key, field, encoded)
    payload[field] = {
      transcriptBodyField: field,
      ...(typeof value === "string" ? { preview: value.slice(0, 512) } : {})
    }
  }
  return payload
}

const writeTranscriptFieldChunks = (
  db: Database.Database,
  itemId: string,
  key: string,
  field: string,
  encoded: string
): void => {
  const insert = db.prepare(bodyChunkSql.insert)
  let offset = 0
  let position = 0
  while (offset < encoded.length) {
    let end = Math.min(encoded.length, offset + blockSize)
    const last = encoded.charCodeAt(end - 1)
    if (end < encoded.length && last >= 0xd800 && last <= 0xdbff) end -= 1
    insert.run(itemId, key, field, position++, encoded.slice(offset, end))
    offset = end
  }
}

export const transcriptBodyResource = (
  db: Database.Database,
  itemId: string,
  key: string
): TranscriptBodyResource | undefined => {
  const fields = bodyFields(db, itemId, key)
  return fields.length === 0 ? undefined : { itemId, entryKey: key, fields }
}

export const readToolSnapshot = (
  db: Database.Database,
  itemId: string,
  toolId: string
): JsonRecord | undefined => {
  const key = `tool:${toolId}`
  const snapshot = toolSnapshot(db, itemId, key)
  if (snapshot === undefined) return undefined
  const resource = transcriptBodyResource(db, itemId, key)
  return {
    ...snapshot.payload,
    isSnapshot: true,
    stateRevision: snapshot.revision,
    statePosition: snapshot.position,
    ...(resource === undefined ? {} : { detailResource: resource })
  }
}

export const readTranscriptBodyPage = (
  db: Database.Database,
  sessionId: string,
  itemId: string,
  key: string,
  field: string,
  position: number
): TranscriptBodyPage | undefined =>
  db.transaction(() => {
    if (itemId.startsWith("setup:")) return readSetupBodyPage(db, sessionId, itemId, key, position)
    if (field === "text") return readTranscriptTextBodyPage(db, sessionId, itemId, key, position)
    return readTranscriptFieldBodyPage(db, sessionId, itemId, key, field, position)
  })()

const readTranscriptTextBodyPage = (
  db: Database.Database,
  sessionId: string,
  itemId: string,
  key: string,
  position: number
): TranscriptBodyPage | undefined => {
  const metadata = textBodyMetadata(db, sessionId, itemId, key)
  if (metadata === undefined) return undefined
  const chunks = textBodyChunks(db, itemId, key, position)
  if (chunks[0] === undefined) return undefined
  return {
    revision: payloadGeneration(metadata.payload, metadata.revision),
    encoding: "text" as const,
    text: chunks[0].text,
    position: chunks[0].position,
    ...(chunks[1] === undefined ? {} : { nextPosition: chunks[1].position })
  }
}

const readTranscriptFieldBodyPage = (
  db: Database.Database,
  sessionId: string,
  itemId: string,
  key: string,
  field: string,
  position: number
): TranscriptBodyPage | undefined => {
  const metadata = fieldBodyMetadata(db, sessionId, itemId, key, field)
  if (metadata === undefined) return undefined
  const chunks = fieldBodyChunks(db, itemId, key, field, position)
  const first = chunks[0]
  if (first === undefined) return undefined
  return {
    ...metadata,
    text: first.text,
    position: first.position,
    ...(chunks[1] === undefined ? {} : { nextPosition: chunks[1].position })
  }
}

export const transcriptTextResource = (
  db: Database.Database,
  itemId: string,
  key: string
): TranscriptBodyResource | undefined => {
  const entry = textResourceEntry(db, itemId, key)
  if (entry === undefined) return undefined
  return {
    itemId,
    entryKey: key,
    fields: [
      {
        name: "text",
        revision: entry.revision,
        encoding: "text",
        sizeBytes: entry.textLength * 2,
        pageCount: entry.pageCount,
        generation: payloadGeneration(entry.payload, entry.revision)
      }
    ]
  }
}

export const inlineTranscriptFields = (payload: JsonRecord): JsonRecord =>
  Object.fromEntries(
    Object.entries(payload).flatMap(([key, value]) => {
      if (typeof value !== "object" || value === null || !("transcriptBodyField" in value))
        return [[key, value]]
      return "preview" in value ? [[key, value.preview]] : []
    })
  )

interface ToolSnapshot {
  readonly payload: JsonRecord
  readonly revision: number
  readonly position: number
}

interface TextResourceEntry {
  readonly revision: number
  readonly textLength: number
  readonly payload: string
  readonly pageCount: number
}

type TextBodyMetadata = ReturnType<typeof textBodyMetadataRows.one>

type FieldBodyMetadata = ReturnType<typeof fieldBodyMetadataRows.one>

type BodyChunk = ReturnType<typeof bodyChunkRows.one>

const bodyFields = (
  db: Database.Database,
  itemId: string,
  key: string
): TranscriptBodyResource["fields"] =>
  bodyFieldRows.all(db.prepare(bodyFieldSql.forEntry).all(itemId, key))

const toolSnapshot = (
  db: Database.Database,
  itemId: string,
  key: string
): ToolSnapshot | undefined => {
  const row = toolSnapshotRows.maybe(db.prepare(toolSnapshotSql).get(itemId, key))
  if (row === undefined) return undefined
  return {
    payload: inlineTranscriptFields(parseJsonObject(row.payload)),
    revision: row.revision,
    position: row.position
  }
}

const textBodyMetadata = (
  db: Database.Database,
  sessionId: string,
  itemId: string,
  key: string
): TextBodyMetadata | undefined =>
  textBodyMetadataRows.maybe(db.prepare(textBodySql.metadata).get(itemId, sessionId, key))

const textBodyChunks = (
  db: Database.Database,
  itemId: string,
  key: string,
  position: number
): ReadonlyArray<BodyChunk> =>
  bodyChunkRows.all(db.prepare(textBodySql.chunks).all(itemId, key, position))

const fieldBodyMetadata = (
  db: Database.Database,
  sessionId: string,
  itemId: string,
  key: string,
  field: string
): FieldBodyMetadata | undefined =>
  fieldBodyMetadataRows.maybe(db.prepare(bodyFieldSql.metadata).get(itemId, sessionId, key, field))

const fieldBodyChunks = (
  db: Database.Database,
  itemId: string,
  key: string,
  field: string,
  position: number
): ReadonlyArray<BodyChunk> =>
  bodyChunkRows.all(db.prepare(bodyChunkSql.page).all(itemId, key, field, position))

const textResourceEntry = (
  db: Database.Database,
  itemId: string,
  key: string
): TextResourceEntry | undefined => {
  const row = textResourceRows.maybe(db.prepare(textBodySql.resource).get(itemId, key))
  if (row === undefined) return undefined
  return {
    revision: row.revision,
    textLength: row.text_length,
    payload: row.payload,
    pageCount: row.page_count
  }
}

const bodyFieldSql = {
  delete: "delete from transcript_body_fields where item_id = ? and entry_key = ? and field = ?",
  insert: `insert into transcript_body_fields (item_id, entry_key, field, revision, encoding, size_bytes)
      values (?, ?, ?, ?, ?, ?)`,
  forEntry: `select field as name, revision, encoding, size_bytes as sizeBytes,
      (select position + 1 from transcript_body_chunks c
       where c.item_id = b.item_id and c.entry_key = b.entry_key and c.field = b.field
       order by position desc limit 1) as pageCount
    from transcript_body_fields b where item_id = ? and entry_key = ? order by field`,
  metadata: `select body.revision, body.encoding from transcript_body_fields body
    join chat_items item on item.id = body.item_id
    where body.item_id = ? and item.session_id = ? and body.entry_key = ? and body.field = ?`
}

const bodyChunkSql = {
  deleteField:
    "delete from transcript_body_chunks where item_id = ? and entry_key = ? and field = ?",
  insert:
    "insert into transcript_body_chunks (item_id, entry_key, field, position, text) values (?, ?, ?, ?, ?)",
  page: `select text, position from transcript_body_chunks
    where item_id = ? and entry_key = ? and field = ? and position >= ? order by position limit 2`
}

const toolSnapshotSql =
  "select payload, revision, position from transcript_entries where item_id = ? and entry_key = ?"

const textBodySql = {
  metadata: `select e.revision, e.payload from transcript_entries e join chat_items i on i.id = e.item_id
      where e.item_id = ? and i.session_id = ? and e.entry_key = ? and e.category in ('text', 'plan')`,
  chunks: `select text, position from transcript_text_chunks where item_id = ? and entry_key = ? and position >= ?
      order by position limit 2`,
  resource: `select revision, text_length, payload,
        (select coalesce(max(position) + 1, 0) from transcript_text_chunks
         where item_id = e.item_id and entry_key = e.entry_key) as page_count
       from transcript_entries e where item_id = ? and entry_key = ?`
}
