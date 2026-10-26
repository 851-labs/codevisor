import type Database from "better-sqlite3"

import { rowReader, text } from "./row-reader.js"

export interface StoredFileReferences {
  readonly fileIds: ReadonlySet<string>
  readonly sha256s: ReadonlySet<string>
}

export const linkSessionFiles = (
  sqlite: Database.Database,
  sessionId: string,
  encodedPayload: string
): void => {
  if (!encodedPayload.includes(fileIdKey)) return

  const link = sqlite.prepare(sessionFileSql.link)
  for (const fileId of referencedFileIds(encodedPayload)) link.run(sessionId, fileId)
}

export const deleteSessionWithFiles = (
  sqlite: Database.Database,
  sessionId: string,
  deleteSession: () => void
): void => {
  const owned = ownedFileIds(sqlite, sessionId)
  deleteSession()

  const purge = sqlite.prepare(sessionFileSql.deleteUnowned)
  for (const fileId of owned) purge.run(fileId, fileId)
}

export const storedFileReferences = (sqlite: Database.Database): StoredFileReferences => {
  const rows = storedFileRows.all(sqlite.prepare(sessionFileSql.storedFiles).all())
  return {
    fileIds: new Set(rows.map((row) => row.id)),
    sha256s: new Set(rows.map((row) => row.sha256))
  }
}

const fileIdKey = '"fileId":"'

const fileIdPattern = /"fileId":"([^"\\]+)"/g

const referencedFileIds = (encodedPayload: string): ReadonlySet<string> =>
  new Set([...encodedPayload.matchAll(fileIdPattern)].map((match) => match[1]!))

const ownedFileIds = (sqlite: Database.Database, sessionId: string): ReadonlyArray<string> =>
  ownedFileRows.all(sqlite.prepare(sessionFileSql.owned).all(sessionId)).map((row) => row.file_id)

const ownedFileRows = rowReader({ file_id: text })

const storedFileRows = rowReader({ id: text, sha256: text })

const sessionFileSql = {
  link: `insert or ignore into session_files (session_id, file_id)
           select ?, id from files where id = ?`,
  owned: "select file_id from session_files where session_id = ?",
  deleteUnowned: `delete from files where id = ? and purge_with_chats = 1
           and not exists (select 1 from session_files where file_id = ?)`,
  storedFiles: "select id, sha256 from files"
}
