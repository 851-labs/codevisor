import type Database from "better-sqlite3"
import type { Effect } from "effect"

import { idRows } from "./common-rows.js"
import { attempt, type DatabaseError } from "./errors.js"
import { canonicalUuid } from "./ids.js"
import type { ServiceContext } from "./service-context.js"

export const SAVED_CHAT_FORMAT = 1

export type SavedChatValue = string | number | null
export type SavedChatRow = Readonly<Record<string, SavedChatValue>>

export interface SavedChatItem {
  readonly item: SavedChatRow
  readonly children: Readonly<Record<string, ReadonlyArray<SavedChatRow>>>
}

export interface SavedChatService {
  readonly listChatItemIds: (
    sessionId: string
  ) => Effect.Effect<ReadonlyArray<string>, DatabaseError>
  readonly listChatFileIds: (
    sessionId: string
  ) => Effect.Effect<ReadonlyArray<string>, DatabaseError>
  readonly exportChatItem: (itemId: string) => Effect.Effect<SavedChatItem, DatabaseError>
  readonly importChatItem: (
    sessionId: string,
    saved: SavedChatItem
  ) => Effect.Effect<void, DatabaseError>
  readonly finishChatImport: (
    sessionId: string,
    fileIds: ReadonlyArray<string>
  ) => Effect.Effect<void, DatabaseError>
}

export const savedChatItemColumns = [
  "id",
  "session_id",
  "position",
  "role",
  "message_id",
  "status",
  "created_at",
  "updated_at",
  "turn_id",
  "started_at",
  "completed_at",
  "stop_reason",
  "stop_detail",
  "attachments",
  "has_details",
  "revision",
  "retryable",
  "stop_kind",
  "plan_proposed_at",
  "plan_resumed_at",
  "origin",
  "attribution",
  "sent_by_agent_id",
  "sent_by_agent_machine_id"
] as const

export const savedChatChildColumns: Readonly<Record<string, ReadonlyArray<string>>> = {
  chat_parts: ["id", "item_id", "position", "kind", "text", "data_json", "revision"],
  chat_item_file_changes: [
    "item_id",
    "tool_call_id",
    "path",
    "added",
    "removed",
    "status",
    "updated_at"
  ],
  chat_item_media: ["item_id", "file_id", "created_at"],
  transcript_entries: [
    "item_id",
    "entry_key",
    "position",
    "revision",
    "parent_id",
    "category",
    "text_length",
    "phase",
    "payload"
  ],
  transcript_heads: ["item_id", "parent_id", "entry_key", "category"],
  transcript_text_chunks: ["item_id", "entry_key", "position", "char_offset", "text"],
  transcript_body_fields: ["item_id", "entry_key", "field", "revision", "encoding", "size_bytes"],
  transcript_body_chunks: ["item_id", "entry_key", "field", "position", "text"]
}

const childTablesNeedingFiles = new Set(["chat_item_media"])

export const makeSavedChatService = ({ sqlite }: ServiceContext): SavedChatService => ({
  listChatItemIds: (sessionId) =>
    attempt("listChatItemIds", () =>
      idRows.all(sqlite.prepare(savedChatSql.itemIds).all(canonicalUuid(sessionId))).map(idOf)
    ),
  listChatFileIds: (sessionId) =>
    attempt("listChatFileIds", () =>
      idRows.all(sqlite.prepare(savedChatSql.fileIds).all(canonicalUuid(sessionId))).map(idOf)
    ),
  exportChatItem: (itemId) => attempt("exportChatItem", () => exportItem(sqlite, itemId)),
  importChatItem: (sessionId, saved) =>
    attempt("importChatItem", () => {
      sqlite.transaction(() => importItem(sqlite, canonicalUuid(sessionId), saved))()
    }),
  finishChatImport: (sessionId, fileIds) =>
    attempt("finishChatImport", () => {
      const id = canonicalUuid(sessionId)
      sqlite.transaction(() => {
        const link = sqlite.prepare(savedChatSql.linkFile)
        for (const fileId of fileIds) link.run(id, fileId)
        if (sqlite.prepare(savedChatSql.hasItems).get(id) !== undefined)
          sqlite.prepare(savedChatSql.saveChatState).run(id, id)
      })()
    })
})

const idOf = (row: { readonly id: string }): string => row.id

const exportItem = (sqlite: Database.Database, itemId: string): SavedChatItem => {
  const item = savedRows(sqlite.prepare(itemSql.select).all(itemId))[0]
  if (item === undefined) throw new Error(`Chat item not found: ${itemId}`)

  const children: Record<string, ReadonlyArray<SavedChatRow>> = {}
  for (const [table, sql] of childSql) {
    children[table] = savedRows(sqlite.prepare(sql.select).all(itemId))
  }
  return { item, children }
}

const importItem = (sqlite: Database.Database, sessionId: string, saved: SavedChatItem): void => {
  const itemId = saved.item["id"]
  if (typeof itemId !== "string") throw new Error("A saved chat item has no id")

  const status = saved.item["status"] === "streaming" ? "complete" : (saved.item["status"] ?? null)
  insertRow(sqlite, itemSql, { ...saved.item, session_id: sessionId, status })
  for (const [table, rows] of Object.entries(saved.children)) {
    const sql = childSql.get(table)
    if (sql === undefined) {
      throw new Error(`A saved chat has rows this server can't place: ${table}`)
    }
    for (const row of rows) {
      if (childTablesNeedingFiles.has(table) && !fileExists(sqlite, row["file_id"])) continue
      insertRow(sqlite, sql, { ...row, item_id: itemId })
    }
  }
}

const fileExists = (sqlite: Database.Database, fileId: SavedChatValue | undefined): boolean =>
  sqlite.prepare(savedChatSql.fileExists).get(fileId) !== undefined

const insertRow = (sqlite: Database.Database, sql: TableSql, row: SavedChatRow): void => {
  sqlite.prepare(sql.insert).run(...sql.columns.map((column) => row[column] ?? null))
}

const savedRows = (rows: ReadonlyArray<unknown>): ReadonlyArray<SavedChatRow> =>
  rows.map((row) => {
    const saved: Record<string, SavedChatValue> = {}
    for (const [column, value] of Object.entries(isRecord(row) ? row : {})) {
      saved[column] = typeof value === "string" || typeof value === "number" ? value : null
    }
    return saved
  })

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null

interface TableSql {
  readonly columns: ReadonlyArray<string>
  readonly select: string
  readonly insert: string
}

const tableSql = (table: string, columns: ReadonlyArray<string>, key: string): TableSql => ({
  columns,
  select: `select ${columns.join(", ")} from ${table} where ${key} = ? order by rowid`,
  insert: `insert into ${table} (${columns.join(", ")}) values (${columns.map(() => "?").join(", ")})`
})

const itemSql = tableSql("chat_items", savedChatItemColumns, "id")

const childSql = new Map(
  Object.entries(savedChatChildColumns).map(([table, columns]) => [
    table,
    tableSql(table, columns, "item_id")
  ])
)

const savedChatSql = {
  itemIds: "select id from chat_items where session_id = ? order by position",
  fileIds: "select file_id as id from session_files where session_id = ? order by file_id",
  fileExists: "select 1 from files where id = ?",
  hasItems: "select 1 from chat_items where session_id = ? limit 1",
  linkFile: `insert or ignore into session_files (session_id, file_id)
    select ?, id from files where id = ?`,
  saveChatState: `insert into session_chat_state (session_id, next_position, current_item_id)
    values (?, (select max(position) + 1 from chat_items where session_id = ?), null)
    on conflict(session_id) do update set next_position = excluded.next_position,
      current_item_id = null`
}
