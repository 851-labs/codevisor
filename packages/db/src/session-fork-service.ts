import { randomUUID } from "node:crypto"

import type Database from "better-sqlite3"
import type { Effect } from "effect"

import { idRows } from "./common-rows.js"
import { attempt, type DatabaseError } from "./errors.js"
import { canonicalUuid } from "./ids.js"
import type { ServiceContext } from "./service-context.js"

export interface ForkMarker {
  readonly text: string
  readonly createdAt: string
}

export interface SessionForkService {
  readonly copySessionTranscript: (
    sourceId: string,
    targetId: string,
    marker: ForkMarker
  ) => Effect.Effect<void, DatabaseError>
}

export const makeSessionForkService = (context: ServiceContext): SessionForkService => ({
  copySessionTranscript: (rawSource, rawTarget, marker) =>
    attempt("copySessionTranscript", () => {
      const { sqlite } = context
      const sourceId = canonicalUuid(rawSource)
      const targetId = canonicalUuid(rawTarget)
      sqlite.transaction(() => {
        mapSourceItems(sqlite, sourceId)
        copyMappedRows(sqlite, sourceId, targetId)
        appendForkMarker(sqlite, targetId, marker)
        sqlite.exec(forkSql.dropMap)
      })()
    })
})

const mapSourceItems = (sqlite: Database.Database, sourceId: string): void => {
  sqlite.exec(forkSql.createMap)
  const insert = sqlite.prepare(forkSql.mapItem)
  for (const { id } of idRows.all(sqlite.prepare(forkSql.sourceItems).all(sourceId))) {
    insert.run(id, randomUUID())
  }
}

const copyMappedRows = (sqlite: Database.Database, sourceId: string, targetId: string): void => {
  sqlite.prepare(forkSql.copyItems).run(targetId, sourceId)
  for (const statement of forkSql.copyItemChildren) sqlite.prepare(statement).run()
  sqlite.prepare(forkSql.copyFiles).run(targetId, sourceId)
}

const appendForkMarker = (
  sqlite: Database.Database,
  targetId: string,
  marker: ForkMarker
): void => {
  const itemId = randomUUID()
  sqlite
    .prepare(forkSql.insertMarker)
    .run(itemId, targetId, targetId, marker.createdAt, marker.createdAt)
  sqlite.prepare(forkSql.insertMarkerText).run(randomUUID(), itemId, marker.text)
  sqlite.prepare(forkSql.saveChatState).run(targetId, targetId)
}

const newUuidSql = `lower(hex(randomblob(4)) || '-' || hex(randomblob(2)) || '-4' ||
  substr(hex(randomblob(2)), 2) || '-' || substr('89ab', 1 + (abs(random()) % 4), 1) ||
  substr(hex(randomblob(2)), 2) || '-' || hex(randomblob(6)))`

const forkSql = {
  createMap: "create temp table fork_item_map (old_id text primary key, new_id text not null)",
  dropMap: "drop table fork_item_map",
  sourceItems: "select id from chat_items where session_id = ? order by position",
  mapItem: "insert into fork_item_map (old_id, new_id) values (?, ?)",
  copyItems: `insert into chat_items (id, session_id, position, role, message_id, status, created_at,
      updated_at, turn_id, started_at, completed_at, stop_reason, stop_detail, attachments,
      has_details, revision, retryable, stop_kind, plan_proposed_at, plan_resumed_at, origin,
      attribution)
    select map.new_id, ?, item.position, item.role, item.message_id,
      item.status, item.created_at,
      item.updated_at, item.turn_id, item.started_at, item.completed_at, item.stop_reason,
      item.stop_detail, item.attachments, item.has_details, item.revision, item.retryable,
      item.stop_kind, item.plan_proposed_at, item.plan_resumed_at, item.origin, item.attribution
    from chat_items as item join fork_item_map as map on map.old_id = item.id
    where item.session_id = ?`,
  copyItemChildren: [
    `insert into chat_parts (id, item_id, position, kind, text, data_json, revision)
      select ${newUuidSql}, map.new_id, part.position, part.kind, part.text,
        part.data_json, part.revision
      from chat_parts as part join fork_item_map as map on map.old_id = part.item_id`,
    `insert into chat_item_file_changes (item_id, tool_call_id, path, added, removed, status, updated_at)
      select map.new_id, change.tool_call_id, change.path, change.added, change.removed,
        change.status, change.updated_at
      from chat_item_file_changes as change join fork_item_map as map on map.old_id = change.item_id`,
    `insert into chat_item_media (item_id, file_id, created_at)
      select map.new_id, media.file_id, media.created_at
      from chat_item_media as media join fork_item_map as map on map.old_id = media.item_id`,
    `insert into transcript_entries (item_id, entry_key, position, revision, parent_id, category,
        text_length, phase, payload)
      select map.new_id, entry.entry_key, entry.position, entry.revision, entry.parent_id,
        entry.category, entry.text_length, entry.phase, entry.payload
      from transcript_entries as entry join fork_item_map as map on map.old_id = entry.item_id`,
    `insert into transcript_heads (item_id, parent_id, entry_key, category)
      select map.new_id, head.parent_id, head.entry_key, head.category
      from transcript_heads as head join fork_item_map as map on map.old_id = head.item_id`,
    `insert into transcript_text_chunks (item_id, entry_key, position, char_offset, text)
      select map.new_id, chunk.entry_key, chunk.position, chunk.char_offset, chunk.text
      from transcript_text_chunks as chunk join fork_item_map as map on map.old_id = chunk.item_id`,
    `insert into transcript_body_fields (item_id, entry_key, field, revision, encoding, size_bytes)
      select map.new_id, body.entry_key, body.field, body.revision, body.encoding, body.size_bytes
      from transcript_body_fields as body join fork_item_map as map on map.old_id = body.item_id`,
    `insert into transcript_body_chunks (item_id, entry_key, field, position, text)
      select map.new_id, chunk.entry_key, chunk.field, chunk.position, chunk.text
      from transcript_body_chunks as chunk join fork_item_map as map on map.old_id = chunk.item_id`
  ],
  copyFiles: `insert or ignore into session_files (session_id, file_id)
    select ?, file_id from session_files where session_id = ?`,
  insertMarker: `insert into chat_items (id, session_id, position, role, status, created_at,
      updated_at, origin)
    values (?, ?, (select coalesce(max(position), -1) + 1 from chat_items where session_id = ?),
      'user', 'complete', ?, ?, 'fork')`,
  insertMarkerText:
    "insert into chat_parts (id, item_id, position, kind, text) values (?, ?, 0, 'text', ?)",
  saveChatState: `insert into session_chat_state (session_id, next_position, current_item_id)
    values (?, (select max(position) + 1 from chat_items where session_id = ?), null)
    on conflict(session_id) do update set next_position = excluded.next_position,
      current_item_id = null`
}
