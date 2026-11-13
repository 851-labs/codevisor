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

export const chatFileSourceCount = (): number => chatFileSources.length

export const linkStoredChatFiles = (
  sqlite: Database.Database,
  onSourceLinked: (linked: number) => void
): void => {
  const link = sqlite.prepare(sessionFileSql.link)
  for (const [index, source] of chatFileSources.entries()) {
    for (const reference of chatFileReferences(sqlite, source)) {
      link.run(reference.sessionId, reference.fileId)
    }
    onSourceLinked(index + 1)
  }
  sqlite.prepare(sessionFileSql.purgeLinkedLegacyFiles).run()
}

export const storedFileReferences = (sqlite: Database.Database): StoredFileReferences => {
  const rows = storedFileRows.all(sqlite.prepare(sessionFileSql.storedFiles).all())
  return {
    fileIds: new Set(rows.map((row) => row.id)),
    sha256s: new Set(rows.map((row) => row.sha256))
  }
}

const fileIdKey = "fileId"

const fileIdPattern = /\\*"fileId\\*":\\*"([^"\\]+)/g

export const referencedFileIds = (encodedPayload: string): ReadonlySet<string> =>
  new Set([...encodedPayload.matchAll(fileIdPattern)].map((match) => match[1]!))

interface ChatFileReference {
  readonly sessionId: string
  readonly fileId: string
}

const chatFileReferences = (
  sqlite: Database.Database,
  source: string
): ReadonlyArray<ChatFileReference> => {
  const references: Array<ChatFileReference> = []
  for (const raw of sqlite.prepare(source).iterate()) {
    const row = chatFileRows.one(raw)
    for (const fileId of referencedFileIds(row.encoded)) {
      references.push({ sessionId: row.session_id, fileId })
    }
  }
  return references
}

const chatFileRows = rowReader({ session_id: text, encoded: text })

const storedFileRows = rowReader({ id: text, sha256: text })

const chatFileSources = [
  `select session_id, attachments as encoded from chat_items
     where attachments like '%fileId%'`,
  `select chat_items.session_id, json_object('fileId', chat_item_media.file_id) as encoded
     from chat_item_media join chat_items on chat_items.id = chat_item_media.item_id`,
  `select chat_items.session_id, transcript_entries.payload as encoded
     from transcript_entries join chat_items on chat_items.id = transcript_entries.item_id
     where transcript_entries.payload like '%fileId%'`,
  `select chat_items.session_id, transcript_body_chunks.text as encoded
     from transcript_body_chunks join chat_items on chat_items.id = transcript_body_chunks.item_id
     where transcript_body_chunks.text like '%fileId%'`,
  `select session_id, attachments as encoded from conversation_items
     where attachments like '%fileId%'`,
  `select session_id, payload as encoded from session_events
     where payload like '%fileId%'`
]

const sessionFileSql = {
  link: `insert or ignore into session_files (session_id, file_id)
           select ?, id from files where id = ?`,
  purgeLinkedLegacyFiles: `update files set purge_with_chats = 1
           where purge_with_chats = 0
             and exists (select 1 from session_files where file_id = files.id)`,
  storedFiles: "select id, sha256 from files"
}
