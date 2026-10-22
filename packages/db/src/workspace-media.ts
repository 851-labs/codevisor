import type { WorkspacePhoto } from "@codevisor/api"

import { attempt } from "./errors.js"
import { canonicalUuid } from "./ids.js"
import { integer, nullable, rowReader, text } from "./row-reader.js"
import type { ServiceContext } from "./service-context.js"
import type { CodevisorDatabaseService } from "./service.js"

export interface WorkspaceMediaCursor {
  readonly createdAt: string
  readonly id: string
}

export interface WorkspaceMediaRow extends WorkspacePhoto {
  readonly sha256: string
  readonly durationProbed: boolean
  readonly durationMs?: number
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

const mediaRows = rowReader({
  file_id: text,
  item_id: text,
  session_id: text,
  created_at: text,
  source: text,
  name: text,
  mime_type: text,
  size_bytes: integer,
  sha256: text,
  duration_probed: integer,
  duration_ms: nullable(integer)
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
  | "listWorkspaceMedia"
  | "recordMediaDuration"
  | "listWorkspaceMessageTexts"
  | "listWorkspaceFileEdits"
> => {
  const { sqlite } = context

  return {
    listWorkspaceMedia: (workspaceId, includeVideos, before, limit) =>
      attempt("listWorkspaceMedia", () =>
        mediaRows
          .all(
            sqlite.prepare(workspaceMediaSql).all({
              workspaceId: canonicalUuid(workspaceId),
              includeVideos: includeVideos ? 1 : 0,
              limit,
              ...cursorParameters(before)
            })
          )
          .map(workspaceMediaFromRow)
      ),
    recordMediaDuration: (sha256, durationMs) =>
      attempt("recordMediaDuration", () => {
        sqlite.prepare(mediaDurationUpsertSql).run(sha256, durationMs ?? null)
      }),
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

const workspaceMediaFromRow = (row: ReturnType<typeof mediaRows.one>): WorkspaceMediaRow => ({
  attachment: {
    fileId: row.file_id,
    name: row.name,
    mimeType: row.mime_type,
    sizeBytes: row.size_bytes,
    kind: row.mime_type.startsWith("image/") ? "image" : "file"
  },
  sessionId: canonicalUuid(row.session_id),
  itemId: row.item_id,
  createdAt: row.created_at,
  source: row.source === "tool" ? "tool" : "message",
  sha256: row.sha256,
  durationProbed: row.duration_probed === 1,
  ...(row.duration_ms === null ? {} : { durationMs: row.duration_ms })
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

const workspaceMediaSql = `with candidates as (
                   select json_extract(attachment.value, '$.fileId') as file_id, item.id as item_id,
                     item.session_id, item.created_at, 'message' as source,
                     json_extract(attachment.value, '$.kind') = 'image' as image_kind
                   from sessions
                   join chat_items item on item.session_id = sessions.id
                   join json_each(
                     case when json_valid(item.attachments) then item.attachments else '[]' end
                   ) attachment
                   where sessions.workspace_id = @workspaceId
                     and (@includeVideos = 1 or json_extract(attachment.value, '$.kind') = 'image')
                   union all
                   select media.file_id, item.id, item.session_id, media.created_at, 'tool', 1
                   from sessions
                   join chat_items item on item.session_id = sessions.id
                   join chat_item_media media on media.item_id = item.id
                   where sessions.workspace_id = @workspaceId
                 ),
                 ranked as (
                   select candidates.*, files.name, files.mime_type, files.size_bytes, files.sha256,
                     row_number() over (
                       partition by files.sha256
                       order by candidates.created_at desc, candidates.file_id desc
                     ) as copy
                   from candidates join files on files.id = candidates.file_id
                   where (candidates.image_kind and files.mime_type like 'image/%')
                     or (@includeVideos = 1 and files.mime_type like 'video/%')
                 )
                 select file_id, item_id, session_id, created_at, source, name, mime_type, size_bytes,
                   ranked.sha256, durations.sha256 is not null as duration_probed,
                   durations.duration_ms
                 from ranked
                 left join media_durations durations on durations.sha256 = ranked.sha256
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

const mediaDurationUpsertSql = `insert into media_durations (sha256, duration_ms) values (?, ?)
              on conflict (sha256) do update set duration_ms = excluded.duration_ms`
