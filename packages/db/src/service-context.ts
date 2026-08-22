import type { Project, SessionSummary } from "@codevisor/api"
import { isoTimestamp } from "@codevisor/api"
import type Database from "better-sqlite3"
import { canonicalUuid } from "./ids.js"
import { projectFromRow, sessionFromRow } from "./row-mappers.js"
import type { ProjectLocationRow, ProjectRow, SessionRow } from "./rows.js"
import type { CodevisorDatabaseConfig } from "./service.js"

/// The state the `createService` closure captures, plus the shared helpers
/// bound to it. Domain factories receive this as their single dependency and
/// destructure exactly the pieces they use.
export interface ServiceContext {
  readonly sqlite: Database.Database
  readonly config: CodevisorDatabaseConfig
  readonly locationRowsFor: (projectId: string) => ReadonlyArray<ProjectLocationRow>
  readonly localLocationFor: (projectId: string) => ProjectLocationRow | undefined
  readonly sessionSummarySelect: string
  readonly getProject: (id: string) => Project
  readonly getSession: (rawId: string) => SessionSummary
}

/// Resolves the `archived_at` value for a write that may or may not be
/// changing the archived state. Re-archiving an already-archived row keeps the
/// original moment rather than refreshing it, so "archived 3 weeks ago" does
/// not reset to "just now" when an unrelated field is updated in the same
/// PATCH.
export const archivedStamp = (
  requested: boolean | undefined,
  currentlyArchived: boolean,
  currentStamp: string | undefined
): string | null => {
  const next = requested ?? currentlyArchived
  if (!next) return null
  return currentStamp ?? isoTimestamp()
}

export const createServiceContext = (
  sqlite: Database.Database,
  config: CodevisorDatabaseConfig
): ServiceContext => {
  const locationRowsFor = (projectId: string): ReadonlyArray<ProjectLocationRow> =>
    sqlite
      .prepare("select * from project_locations where project_id = ? order by created_at asc")
      .all(projectId) as ReadonlyArray<ProjectLocationRow>

  const localLocationFor = (projectId: string): ProjectLocationRow | undefined =>
    sqlite
      .prepare("select * from project_locations where project_id = ? and server_id = ?")
      .get(projectId, config.serverId) as ProjectLocationRow | undefined

  // Attention is owned by the server and read state is shared by every
  // device authenticated as this server's owner. Unread is a plain revision
  // delta against the shared cursor (a manual unread reads as at least 1);
  // `errored` is intrinsic state, not a property of unread events.
  const sessionSummarySelect = `
    select sessions.*,
      coalesce((
        select attention_revision from session_attention sa
        where sa.session_id = sessions.id
      ), 0) as attention_latest_sequence,
      coalesce((
        select last_seen_sequence from session_read_state rs
        where rs.session_id = sessions.id and rs.reader_id = 'owner'
      ), 0) as attention_last_seen_sequence,
      max(
        max(
          coalesce((
            select attention_revision from session_attention sa
            where sa.session_id = sessions.id
          ), 0) - coalesce((
            select last_seen_sequence from session_read_state rs
            where rs.session_id = sessions.id and rs.reader_id = 'owner'
          ), 0),
          0
        ),
        coalesce((
          select manually_unread from session_read_state rs
          where rs.session_id = sessions.id and rs.reader_id = 'owner'
        ), 0)
      ) as attention_unread_count,
      coalesce((
        select manually_unread from session_read_state rs
        where rs.session_id = sessions.id and rs.reader_id = 'owner'
      ), 0) as attention_manually_unread,
      coalesce((
        select errored from session_attention sa
        where sa.session_id = sessions.id
      ), 0) as attention_has_unread_error,
      coalesce((
        select pending_plan_approval from session_attention sa
        where sa.session_id = sessions.id
      ), 0) as pending_plan_approval
    from sessions`

  const getProject = (id: string): Project => {
    // Case-insensitive: UUID identifiers may arrive in either case. Use the
    // stored id (row.id) for the location lookup so it matches exactly.
    const row = sqlite.prepare("select * from projects where id = ? collate nocase").get(id) as
      | ProjectRow
      | undefined
    if (row === undefined) {
      throw new Error(`Project not found: ${id}`)
    }
    return projectFromRow(row, locationRowsFor(row.id))
  }

  const getSession = (rawId: string): SessionSummary => {
    // Stored session ids are canonically lowercase; tolerate uppercase ids
    // from Swift clients by normalizing the argument (see canonicalUuid).
    const id = canonicalUuid(rawId)
    const row = sqlite.prepare(`${sessionSummarySelect} where sessions.id = ?`).get(id) as
      | SessionRow
      | undefined
    if (row === undefined) {
      throw new Error(`Session not found: ${id}`)
    }
    return sessionFromRow(row, localLocationFor(row.project_id)?.folder_path)
  }

  return {
    sqlite,
    config,
    locationRowsFor,
    localLocationFor,
    sessionSummarySelect,
    getProject,
    getSession
  }
}
