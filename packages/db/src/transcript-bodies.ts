import type { TranscriptBodyPage, TranscriptBodyResource } from "@codevisor/api"
import type Database from "better-sqlite3"

import type { JsonRecord } from "./event-payloads.js"
import { readSetupBodyPage } from "./setup-state.js"

const blockSize = 8192

/** Store oversized fields in separately paged blocks. Status-only tool
 * updates then touch metadata without reading/copying the old output. */
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
    db.prepare(
      "delete from transcript_body_chunks where item_id = ? and entry_key = ? and field = ?"
    ).run(itemId, key, field)
    db.prepare(
      "delete from transcript_body_fields where item_id = ? and entry_key = ? and field = ?"
    ).run(itemId, key, field)
    if (bytes <= 16 * 1024 && (inlineBytes + bytes <= 32 * 1024 || bytes < 512)) {
      payload[field] = value
      inlineBytes += bytes
      continue
    }
    db.prepare(
      `insert into transcript_body_fields (item_id, entry_key, field, revision, encoding, size_bytes)
      values (?, ?, ?, ?, ?, ?)`
    ).run(itemId, key, field, revision, typeof value === "string" ? "text" : "json", bytes)
    const insert = db.prepare(
      "insert into transcript_body_chunks (item_id, entry_key, field, position, text) values (?, ?, ?, ?, ?)"
    )
    let offset = 0
    let position = 0
    while (offset < encoded.length) {
      let end = Math.min(encoded.length, offset + blockSize)
      const last = encoded.charCodeAt(end - 1)
      if (end < encoded.length && last >= 0xd800 && last <= 0xdbff) end -= 1
      insert.run(itemId, key, field, position++, encoded.slice(offset, end))
      offset = end
    }
    payload[field] = {
      transcriptBodyField: field,
      ...(typeof value === "string" ? { preview: value.slice(0, 512) } : {})
    }
  }
  return payload
}

export const transcriptBodyResource = (
  db: Database.Database,
  itemId: string,
  key: string
): TranscriptBodyResource | undefined => {
  const fields = db
    .prepare(
      `select field as name, revision, encoding, size_bytes as sizeBytes,
      (select position + 1 from transcript_body_chunks c
       where c.item_id = b.item_id and c.entry_key = b.entry_key and c.field = b.field
       order by position desc limit 1) as pageCount
    from transcript_body_fields b where item_id = ? and entry_key = ? order by field`
    )
    .all(itemId, key) as unknown as TranscriptBodyResource["fields"]
  return fields.length === 0 ? undefined : { itemId, entryKey: key, fields }
}

export const readToolSnapshot = (
  db: Database.Database,
  itemId: string,
  toolId: string
): JsonRecord | undefined => {
  const key = `tool:${toolId}`
  const row = db
    .prepare(
      "select payload, revision, position from transcript_entries where item_id = ? and entry_key = ?"
    )
    .get(itemId, key) as { payload: string; revision: number; position: number } | undefined
  if (row === undefined) return undefined
  const payload = inlineTranscriptFields(JSON.parse(row.payload) as JsonRecord)
  const resource = transcriptBodyResource(db, itemId, key)
  return {
    ...payload,
    isSnapshot: true,
    stateRevision: row.revision,
    statePosition: row.position,
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
    if (field === "text") {
      const metadata = db
        .prepare(
          `select e.revision, e.payload from transcript_entries e join chat_items i on i.id = e.item_id
      where e.item_id = ? and i.session_id = ? and e.entry_key = ? and e.category in ('text', 'plan')`
        )
        .get(itemId, sessionId, key) as { revision: number; payload: string } | undefined
      if (metadata === undefined) return undefined
      const chunks = db
        .prepare(
          `select text, position from transcript_text_chunks where item_id = ? and entry_key = ? and position >= ?
      order by position limit 2`
        )
        .all(itemId, key, position) as Array<{ text: string; position: number }>
      if (chunks[0] === undefined) return undefined
      return {
        revision: Number(
          (JSON.parse(metadata.payload) as JsonRecord).generation ?? metadata.revision
        ),
        encoding: "text" as const,
        text: chunks[0].text,
        position: chunks[0].position,
        ...(chunks[1] === undefined ? {} : { nextPosition: chunks[1].position })
      }
    }
    const metadata = db
      .prepare(
        `select body.revision, body.encoding from transcript_body_fields body
    join chat_items item on item.id = body.item_id
    where body.item_id = ? and item.session_id = ? and body.entry_key = ? and body.field = ?`
      )
      .get(itemId, sessionId, key, field) as
      | { revision: number; encoding: "text" | "json" }
      | undefined
    if (metadata === undefined) return undefined
    const chunks = db
      .prepare(
        `select text, position from transcript_body_chunks
    where item_id = ? and entry_key = ? and field = ? and position >= ? order by position limit 2`
      )
      .all(itemId, key, field, position) as Array<{ text: string; position: number }>
    const first = chunks[0]
    if (first === undefined) return undefined
    return {
      ...metadata,
      text: first.text,
      position: first.position,
      ...(chunks[1] === undefined ? {} : { nextPosition: chunks[1].position })
    }
  })()

export const transcriptTextResource = (
  db: Database.Database,
  itemId: string,
  key: string
): TranscriptBodyResource | undefined => {
  const row = db
    .prepare(
      `select revision, text_length, payload,
        (select coalesce(max(position) + 1, 0) from transcript_text_chunks
         where item_id = e.item_id and entry_key = e.entry_key) as page_count
       from transcript_entries e where item_id = ? and entry_key = ?`
    )
    .get(itemId, key) as
    | { revision: number; text_length: number; payload: string; page_count: number }
    | undefined
  return row === undefined
    ? undefined
    : {
        itemId,
        entryKey: key,
        fields: [
          {
            name: "text",
            revision: row.revision,
            encoding: "text",
            sizeBytes: row.text_length * 2,
            pageCount: row.page_count,
            generation: Number((JSON.parse(row.payload) as JsonRecord).generation ?? row.revision)
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
