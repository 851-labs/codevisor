import type Database from "better-sqlite3"

import { rowReader, text } from "./row-reader.js"
import { referencedFileIds } from "./session-files.js"

export interface UnusedFile {
  readonly id: string
  readonly createdAt: string
}

export const unusedFiles = (sqlite: Database.Database): ReadonlyArray<UnusedFile> => {
  const pending = pendingFileIds(sqlite)
  return unlinkedFileRows
    .all(sqlite.prepare(unusedFileSql.unlinked).all())
    .filter((row) => !pending.has(row.id))
    .map((row) => ({ id: row.id, createdAt: row.created_at }))
}

export const deleteFiles = (sqlite: Database.Database, ids: ReadonlyArray<string>): void => {
  const remove = sqlite.prepare(unusedFileSql.delete)
  sqlite.transaction(() => {
    for (const id of ids) remove.run(id)
  })()
}

const pendingFileIds = (sqlite: Database.Database): ReadonlySet<string> => {
  const ids = new Set<string>()
  for (const row of pendingRows.all(sqlite.prepare(unusedFileSql.pending).all())) {
    for (const id of referencedFileIds(row.encoded)) ids.add(id)
  }
  return ids
}

const unlinkedFileRows = rowReader({ id: text, created_at: text })

const pendingRows = rowReader({ encoded: text })

const unusedFileSql = {
  unlinked: `select id, created_at from files
               where not exists (select 1 from session_files where file_id = files.id)`,
  pending: `select attachments as encoded from prompt_queue_items where attachments like '%fileId%'
            union all
            select attachments as encoded from conversation_messages where attachments like '%fileId%'`,
  delete: "delete from files where id = ?"
}
