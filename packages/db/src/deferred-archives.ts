import { isoTimestamp } from "@codevisor/api"
import type Database from "better-sqlite3"
import type { Effect } from "effect"

import { attempt, type DatabaseError } from "./errors.js"
import { canonicalUuid } from "./ids.js"
import { literal, nullable, rowReader, text } from "./row-reader.js"
import type { ServiceContext } from "./service-context.js"

export type DeferredArchiveTarget = "chat" | "workspace"

export interface DeferredArchiveRequest {
  readonly sessionId: string
  readonly target: DeferredArchiveTarget
  readonly workspaceId?: string
}

export interface DeferredArchive extends DeferredArchiveRequest {
  readonly scheduledAt: string
}

export interface DeferredArchivesService {
  readonly scheduleDeferredArchive: (
    request: DeferredArchiveRequest
  ) => Effect.Effect<DeferredArchive, DatabaseError>
  readonly getDueDeferredArchive: (
    sessionId: string
  ) => Effect.Effect<DeferredArchive | undefined, DatabaseError>
  readonly listDueDeferredArchives: Effect.Effect<ReadonlyArray<DeferredArchive>, DatabaseError>
  readonly cancelDeferredArchivesFor: (
    sessionId: string
  ) => Effect.Effect<ReadonlyArray<string>, DatabaseError>
  readonly deleteDeferredArchive: (sessionId: string) => Effect.Effect<boolean, DatabaseError>
}

export const makeDeferredArchivesService = (context: ServiceContext): DeferredArchivesService => {
  const { sqlite, getSession } = context

  return {
    scheduleDeferredArchive: (request) =>
      attempt("scheduleDeferredArchive", () => {
        const scheduled = scheduledArchive(request)
        getSession(scheduled.sessionId)
        sqlite.prepare(deferredArchiveSql.upsert).run(upsertValues(scheduled))
        return scheduled
      }),
    getDueDeferredArchive: (sessionId) =>
      attempt("getDueDeferredArchive", () => {
        const row = deferredArchiveRows.maybe(
          sqlite.prepare(deferredArchiveSql.dueForSession).get(canonicalUuid(sessionId))
        )
        return row === undefined ? undefined : archiveFromRow(row)
      }),
    listDueDeferredArchives: attempt("listDueDeferredArchives", () =>
      deferredArchiveRows.all(sqlite.prepare(deferredArchiveSql.allDue).all()).map(archiveFromRow)
    ),
    cancelDeferredArchivesFor: (sessionId) =>
      attempt("cancelDeferredArchivesFor", () =>
        sessionIdRows
          .all(
            sqlite
              .prepare(deferredArchiveSql.cancelFor)
              .all({ sessionId: canonicalUuid(sessionId) })
          )
          .map((row) => row.session_id)
      ),
    deleteDeferredArchive: (sessionId) =>
      attempt(
        "deleteDeferredArchive",
        () => sqlite.prepare(deferredArchiveSql.delete).run(canonicalUuid(sessionId)).changes > 0
      )
  }
}

export const markDeferredArchiveDue = (sqlite: Database.Database, sessionId: string): void => {
  sqlite.prepare(deferredArchiveSql.markDue).run(sessionId)
}

export const forgetDeferredArchive = (sqlite: Database.Database, sessionId: string): void => {
  sqlite.prepare(deferredArchiveSql.delete).run(sessionId)
}

export const forgetDeferredArchivesIn = (sqlite: Database.Database, workspaceId: string): void => {
  sqlite.prepare(deferredArchiveSql.deleteInWorkspace).run({ workspaceId })
}

const scheduledArchive = (request: DeferredArchiveRequest): DeferredArchive => ({
  sessionId: canonicalUuid(request.sessionId),
  target: request.target,
  ...(request.workspaceId === undefined ? {} : { workspaceId: canonicalUuid(request.workspaceId) }),
  scheduledAt: isoTimestamp()
})

const upsertValues = (archive: DeferredArchive) => ({
  sessionId: archive.sessionId,
  target: archive.target,
  workspaceId: archive.workspaceId ?? null,
  scheduledAt: archive.scheduledAt
})

const archiveFromRow = (row: DeferredArchiveRow): DeferredArchive => ({
  sessionId: row.session_id,
  target: row.target,
  ...(row.workspace_id === null ? {} : { workspaceId: row.workspace_id }),
  scheduledAt: row.scheduled_at
})

interface DeferredArchiveRow {
  readonly session_id: string
  readonly target: DeferredArchiveTarget
  readonly workspace_id: string | null
  readonly scheduled_at: string
}

const deferredArchiveRows = rowReader<DeferredArchiveRow>({
  session_id: text,
  target: literal("chat", "workspace"),
  workspace_id: nullable(text),
  scheduled_at: text
})

const sessionIdRows = rowReader({ session_id: text })

const archiveColumns = "session_id, target, workspace_id, scheduled_at"

const turnIsOver = `coalesce((select turn_active = 0 and pending_finish = 0
  from session_attention where session_id = @sessionId), 1)`

const deferredArchiveSql = {
  upsert: `insert into deferred_archives (session_id, target, workspace_id, scheduled_at, due)
             values (@sessionId, @target, @workspaceId, @scheduledAt, ${turnIsOver})
           on conflict(session_id) do update set target = excluded.target,
             workspace_id = excluded.workspace_id, scheduled_at = excluded.scheduled_at,
             due = excluded.due`,
  dueForSession: `select ${archiveColumns} from deferred_archives where session_id = ? and due = 1`,
  allDue: `select ${archiveColumns} from deferred_archives where due = 1 order by scheduled_at`,
  markDue: "update deferred_archives set due = 1 where session_id = ?",
  cancelFor: `delete from deferred_archives where session_id = @sessionId
                or (target = 'workspace'
                    and workspace_id = (select workspace_id from sessions where id = @sessionId))
              returning session_id`,
  delete: "delete from deferred_archives where session_id = ?",
  deleteInWorkspace: `delete from deferred_archives where workspace_id = @workspaceId
                        or session_id in (select id from sessions where workspace_id = @workspaceId)`
}
