import type { TranscriptItemDetails } from "@codevisor/api"
import type Database from "better-sqlite3"

import type { JsonRecord } from "./event-payloads.js"
import {
  transcriptBodyResource,
  transcriptTextResource,
  readToolSnapshot,
  inlineTranscriptFields
} from "./transcript-bodies.js"
import { readTranscriptText } from "./transcript-state.js"

const maxPageBytes = 96 * 1024
type Cursor = { position: number; key: string; reverse?: boolean }
type EntryRow = {
  entry_key: string
  position: number
  revision: number
  category: string
  text_length: number
  bytes: number
}

export const readTranscriptStatePage = (
  db: Database.Database,
  sessionId: string,
  itemId: string,
  after?: string
): TranscriptItemDetails | undefined =>
  db.transaction(() => {
    const item = db
      .prepare(
        `select chat_items.revision, sessions.revision as cursor from chat_items
    join sessions on sessions.id = chat_items.session_id where chat_items.id = ? and session_id = ?`
      )
      .get(itemId, sessionId) as { revision: number; cursor: number } | undefined
    if (item === undefined) return undefined
    const cursor: Cursor =
      after === "latest"
        ? { position: Number.MAX_SAFE_INTEGER, key: "", reverse: true }
        : after === undefined
          ? { position: -1, key: "" }
          : (JSON.parse(Buffer.from(after, "base64url").toString()) as Cursor)
    if (!Number.isSafeInteger(cursor.position) || typeof cursor.key !== "string") {
      throw new Error("Invalid transcript state cursor")
    }
    const entries: Array<{ key: string; position: number; revision: number; payload: unknown }> = []
    let bytes = 0
    const reverse = cursor.reverse === true
    const rows = db
      .prepare(
        `select entry_key, position, revision, category, text_length, length(cast(payload as blob)) as bytes
    from transcript_entries where item_id = ? and (position, entry_key) ${reverse ? "<" : ">"} (?, ?)
    order by position ${reverse ? "desc" : "asc"}, entry_key ${reverse ? "desc" : "asc"} limit 33`
      )
      .all(itemId, cursor.position, cursor.key) as EntryRow[]
    for (const row of rows) {
      if (entries.length >= 32 || bytes >= maxPageBytes) {
        break
      }
      let payload = inlineTranscriptFields(
        JSON.parse(
          (
            db
              .prepare("select payload from transcript_entries where item_id = ? and entry_key = ?")
              .get(itemId, row.entry_key) as { payload: string }
          ).payload
        ) as JsonRecord
      )
      const resource = transcriptBodyResource(db, itemId, row.entry_key)
      if (resource !== undefined) payload.detailResource = resource
      if (row.category === "tool") {
        payload.isSnapshot = true
        payload.stateRevision = row.revision
        payload.statePosition = row.position
      }
      if (row.category === "text" || row.category === "plan") {
        const text = readTranscriptText(db, itemId, row.entry_key, 24_000)
        const resource = transcriptTextResource(db, itemId, row.entry_key)
        payload =
          row.category === "text"
            ? {
                ...payload,
                sessionUpdate: "agent_message_patch",
                messageId: payload.messageId ?? row.entry_key,
                text,
                offset: 0,
                totalLength: row.text_length,
                generation: payload.generation ?? 0,
                stateRevision: row.revision,
                statePosition: row.position,
                chatItemId: itemId,
                detailResource: resource
              }
            : {
                ...payload,
                markdown: text,
                stateRevision: row.revision,
                ...(row.text_length > text.length ? { detailResource: resource } : {})
              }
      }
      const size = Buffer.byteLength(JSON.stringify(payload))
      if (bytes + size > maxPageBytes && entries.length > 0) {
        break
      }
      entries.push({ key: row.entry_key, position: row.position, revision: row.revision, payload })
      bytes += size
    }
    if (reverse) entries.reverse()
    const first = entries[0]
    const end = entries.at(-1)
    const encode = (entry: { position: number; key: string }, reverse = false): string =>
      Buffer.from(JSON.stringify({ position: entry.position, key: entry.key, reverse })).toString(
        "base64url"
      )
    const hasPrevious =
      first !== undefined &&
      db
        .prepare(
          `select 1 from transcript_entries where item_id = ?
    and (position, entry_key) < (?, ?) limit 1`
        )
        .get(itemId, first.position, first.key) !== undefined
    const hasNext =
      end !== undefined &&
      db
        .prepare(
          `select 1 from transcript_entries where item_id = ?
    and (position, entry_key) > (?, ?) limit 1`
        )
        .get(itemId, end.position, end.key) !== undefined
    // A page may start inside a subagent. Include its compact parent headers so
    // the children remain reachable without retaining all preceding pages.
    const included = new Set(entries.map((entry) => entry.key))
    const parents = new Set(
      entries
        .map((entry) => (entry.payload as JsonRecord).parentToolCallId)
        .filter((id): id is string => typeof id === "string")
    )
    const context = [...parents].flatMap((parent) => {
      const key = `tool:${parent}`
      if (included.has(key)) return []
      const payload = readToolSnapshot(db, itemId, parent)
      if (payload === undefined) return []
      const header = Object.fromEntries(
        [
          "sessionUpdate",
          "toolCallId",
          "title",
          "kind",
          "status",
          "parentToolCallId",
          "isSnapshot",
          "stateRevision",
          "statePosition",
          "detailResource"
        ]
          .filter((field) => payload[field] !== undefined)
          .map((field) => [
            field,
            field === "title" ? String(payload[field]).slice(0, 512) : payload[field]
          ])
      )
      return [
        {
          key,
          position: Number(payload.statePosition),
          revision: Number(payload.stateRevision),
          payload: header
        }
      ]
    })
    return {
      itemId,
      revision: item.revision,
      eventCursor: item.cursor,
      entries: [...context, ...entries],
      ...(hasPrevious ? { previousBefore: encode(first!, true) } : {}),
      ...(hasNext ? { nextAfter: encode(end!) } : {})
    }
  })()
