import type { WorkspacePhoto } from "@codevisor/api"

import { attempt } from "./errors.js"
import { canonicalUuid } from "./ids.js"
import { integer, rowReader, text } from "./row-reader.js"
import type { ServiceContext } from "./service-context.js"
import type { CodevisorDatabaseService } from "./service.js"

export interface WorkspaceMediaCursor {
  readonly createdAt: string
  readonly id: string
}

export interface WorkspaceFileEdit {
  readonly path: string
  readonly added: number
  readonly removed: number
  readonly changedAt: string
  readonly sessionId: string
}

export interface WorkspaceMessageText {
  readonly itemId: string
  readonly sessionId: string
  readonly createdAt: string
  readonly text: string
}

const photoRows = rowReader({
  file_id: text,
  item_id: text,
  session_id: text,
  created_at: text,
  source: text,
  name: text,
  mime_type: text,
  size_bytes: integer
})

const messageTextRows = rowReader({
  item_id: text,
  session_id: text,
  created_at: text,
  text
})

const fileEditRows = rowReader({
  path: text,
  added: integer,
  removed: integer,
  changed_at: text,
  session_id: text
})

const cursorParameters = (before: WorkspaceMediaCursor | undefined) => ({
  beforeCreatedAt: before?.createdAt ?? null,
  beforeId: before?.id ?? null
})

export const makeWorkspaceMediaService = (
  context: ServiceContext
): Pick<
  CodevisorDatabaseService,
  "listWorkspacePhotos" | "listWorkspaceMessageTexts" | "listWorkspaceFileEdits"
> => {
  const { sqlite } = context

  return {
    listWorkspacePhotos: (workspaceId, before, limit) =>
      attempt("listWorkspacePhotos", () =>
        photoRows
          .all(
            sqlite
              .prepare(workspacePhotosSql)
              .all({ workspaceId: canonicalUuid(workspaceId), limit, ...cursorParameters(before) })
          )
          .map(workspacePhotoFromRow)
      ),
    listWorkspaceMessageTexts: (workspaceId, before, limit) =>
      attempt("listWorkspaceMessageTexts", () =>
        messageTextRows
          .all(
            sqlite
              .prepare(workspaceMessageTextsSql)
              .all({ workspaceId: canonicalUuid(workspaceId), limit, ...cursorParameters(before) })
          )
          .map(workspaceMessageTextFromRow)
      ),
    listWorkspaceFileEdits: (workspaceId, limit) =>
      attempt("listWorkspaceFileEdits", () =>
        fileEditRows
          .all(
            sqlite
              .prepare(workspaceFileEditsSql)
              .all({ workspaceId: canonicalUuid(workspaceId), limit })
          )
          .map(workspaceFileEditFromRow)
      )
  }
}

const workspacePhotoFromRow = (row: ReturnType<typeof photoRows.one>): WorkspacePhoto => ({
  attachment: {
    fileId: row.file_id,
    name: row.name,
    mimeType: row.mime_type,
    sizeBytes: row.size_bytes,
    kind: "image"
  },
  sessionId: canonicalUuid(row.session_id),
  itemId: row.item_id,
  createdAt: row.created_at,
  source: row.source === "tool" ? "tool" : "message"
})

const workspaceMessageTextFromRow = (
  row: ReturnType<typeof messageTextRows.one>
): WorkspaceMessageText => ({
  itemId: row.item_id,
  sessionId: canonicalUuid(row.session_id),
  createdAt: row.created_at,
  text: row.text
})

const workspaceFileEditFromRow = (row: ReturnType<typeof fileEditRows.one>): WorkspaceFileEdit => ({
  path: row.path,
  added: row.added,
  removed: row.removed,
  changedAt: row.changed_at,
  sessionId: canonicalUuid(row.session_id)
})

const workspacePhotosSql = `with candidates as (
                   select json_extract(attachment.value, '$.fileId') as file_id, item.id as item_id,
                     item.session_id, item.created_at, 'message' as source
                   from sessions
                   join chat_items item on item.session_id = sessions.id
                   join json_each(
                     case when json_valid(item.attachments) then item.attachments else '[]' end
                   ) attachment
                   where sessions.workspace_id = @workspaceId
                     and json_extract(attachment.value, '$.kind') = 'image'
                   union all
                   select media.file_id, item.id, item.session_id, media.created_at, 'tool'
                   from sessions
                   join chat_items item on item.session_id = sessions.id
                   join chat_item_media media on media.item_id = item.id
                   where sessions.workspace_id = @workspaceId
                 ),
                 ranked as (
                   select candidates.*, files.name, files.mime_type, files.size_bytes,
                     row_number() over (
                       partition by files.sha256
                       order by candidates.created_at desc, candidates.file_id desc
                     ) as copy
                   from candidates join files on files.id = candidates.file_id
                   where files.mime_type like 'image/%'
                 )
                 select file_id, item_id, session_id, created_at, source, name, mime_type, size_bytes
                 from ranked
                 where copy = 1
                   and (@beforeCreatedAt is null or (created_at, file_id) < (@beforeCreatedAt, @beforeId))
                 order by created_at desc, file_id desc
                 limit @limit`

const workspaceMessageTextsSql = `select item.id as item_id, item.session_id, item.created_at, part.text
                 from sessions
                 join chat_items item on item.session_id = sessions.id
                 join chat_parts part on part.item_id = item.id
                 where sessions.workspace_id = @workspaceId
                   and item.role in ('user', 'assistant')
                   and part.kind = 'text'
                   and instr(part.text, '://') > 0
                   and (@beforeCreatedAt is null or (item.created_at, item.id) < (@beforeCreatedAt, @beforeId))
                 order by item.created_at desc, item.id desc, part.position
                 limit @limit`

const workspaceFileEditsSql = `with edits as (
                   select change.path, change.added, change.removed, change.updated_at,
                     item.session_id
                   from sessions
                   join chat_items item on item.session_id = sessions.id
                   join chat_item_file_changes change on change.item_id = item.id
                   where sessions.workspace_id = @workspaceId and change.status = 'completed'
                 ),
                 ranked as (
                   select edits.*,
                     row_number() over (partition by path order by updated_at desc) as recency,
                     sum(added) over (partition by path) as total_added,
                     sum(removed) over (partition by path) as total_removed
                   from edits
                 )
                 select path, total_added as added, total_removed as removed,
                   updated_at as changed_at, session_id
                 from ranked
                 where recency = 1
                 order by updated_at desc, path
                 limit @limit`
