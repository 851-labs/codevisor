import type { Project, SessionSummary } from "@codevisor/api"
import { isoTimestamp } from "@codevisor/api"
import type Database from "better-sqlite3"

import { latestBotMessageColumns } from "./bot-conversation-attention.js"
import { canonicalUuid } from "./ids.js"
import { projectFromRow, sessionFromRow } from "./row-mappers.js"
import { projectLocationRows, projectRows, sessionRows, type ProjectLocationRow } from "./rows.js"
import type { CodevisorDatabaseConfig } from "./service.js"

export interface ServiceContext {
  readonly sqlite: Database.Database
  readonly config: CodevisorDatabaseConfig
  readonly locationRowsFor: (projectId: string) => ReadonlyArray<ProjectLocationRow>
  readonly localLocationFor: (projectId: string) => ProjectLocationRow | undefined
  readonly sessionSummarySelect: string
  readonly getProject: (id: string) => Project
  readonly getSession: (rawId: string) => SessionSummary
}

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
    projectLocationRows.all(
      sqlite
        .prepare("select * from project_locations where project_id = ? order by created_at asc")
        .all(projectId)
    )

  const localLocationFor = (projectId: string): ProjectLocationRow | undefined =>
    projectLocationRows.maybe(
      sqlite
        .prepare("select * from project_locations where project_id = ? and server_id = ?")
        .get(projectId, config.serverId)
    )

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
      ), 0) as pending_plan_approval,${latestBotMessageColumns}
    from sessions`

  const getProject = (id: string): Project => {
    const row = projectRows.maybe(
      sqlite.prepare("select * from projects where id = ? collate nocase").get(id)
    )
    if (row === undefined) {
      throw new Error(`Project not found: ${id}`)
    }
    return projectFromRow(row, locationRowsFor(row.id))
  }

  const getSession = (rawId: string): SessionSummary => {
    const id = canonicalUuid(rawId)
    const row = sessionRows.maybe(
      sqlite.prepare(`${sessionSummarySelect} where sessions.id = ?`).get(id)
    )
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
