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

const cursorParameters = (before: WorkspaceMediaCursor | undefined) => ({
  beforeCreatedAt: before?.createdAt ?? null,
  beforeId: before?.id ?? null
})

export const makeWorkspaceMediaService = (
  context: ServiceContext
): Pick<CodevisorDatabaseService, "listWorkspacePhotos" | "listWorkspaceMessageTexts"> => {
  const { sqlite } = context

  return {
    listWorkspacePhotos: (workspaceId, before, limit) =>
      attempt("listWorkspacePhotos", () =>
        photoRows
          .all(
            sqlite
              .prepare(
                `with candidates as (
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
              )
              .all({ workspaceId: canonicalUuid(workspaceId), limit, ...cursorParameters(before) })
          )
          .map((row): WorkspacePhoto => ({
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
          }))
      ),
    listWorkspaceMessageTexts: (workspaceId, before, limit) =>
      attempt("listWorkspaceMessageTexts", () =>
        messageTextRows
          .all(
            sqlite
              .prepare(
                `select item.id as item_id, item.session_id, item.created_at, part.text
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
              )
              .all({ workspaceId: canonicalUuid(workspaceId), limit, ...cursorParameters(before) })
          )
          .map((row): WorkspaceMessageText => ({
            itemId: row.item_id,
            sessionId: canonicalUuid(row.session_id),
            createdAt: row.created_at,
            text: row.text
          }))
      )
  }
}
