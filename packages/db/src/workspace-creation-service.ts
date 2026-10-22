import { randomUUID } from "node:crypto"

import { isoTimestamp, type SessionSummary, type Workspace } from "@codevisor/api"

import { attempt } from "./errors.js"
import { canonicalUuid } from "./ids.js"
import { nextPanePositionIn } from "./pane-position.js"
import { workspaceFromRow } from "./row-mappers.js"
import type { ServiceContext } from "./service-context.js"
import type { CodevisorDatabaseService } from "./service.js"
import { insertSessionRow } from "./sessions-service.js"
import { readPane } from "./workspace-pane-operations.js"
import type { CreateWorkspaceWithSessionRecord } from "./workspace-service-types.js"
import { readWorkspaceRow, upsertWorkspaceRow } from "./workspaces-service.js"

export const makeWorkspaceCreationService = (
  context: ServiceContext
): Pick<CodevisorDatabaseService, "createWorkspaceWithSession"> => {
  const { sqlite, getSession } = context

  return {
    createWorkspaceWithSession: (request) =>
      attempt("createWorkspaceWithSession", () =>
        sqlite.transaction(() => {
          const workspace = existingOrNewWorkspace(context, request)
          const sessionId = canonicalUuid(request.session.id ?? randomUUID())
          const session = existingOrNewSession(context, request, sessionId, workspace)
          if (session.projectId.toLowerCase() !== workspace.projectId.toLowerCase()) {
            throw new Error(
              `Session ${sessionId} and workspace ${workspace.id} belong to different projects`
            )
          }
          const now = isoTimestamp()
          const paneId = canonicalUuid(request.pane?.id ?? sessionId)
          const title = request.pane?.title ?? (session.title || "Chat")
          sqlite.prepare(creationSql.setSessionWorkspace).run(workspace.id, sessionId)
          sqlite.prepare(creationSql.deleteOtherSessionPanes).run(paneId, sessionId)
          sqlite
            .prepare(creationSql.upsertSessionPane)
            .run(
              paneId,
              workspace.id,
              title,
              sessionId,
              session.createdAt,
              nextPanePositionIn(sqlite, workspace.id, paneId),
              now
            )
          const pane = readPane(sqlite, paneId)
          return { workspace, session: getSession(sessionId), pane }
        })()
      )
  }
}

const existingOrNewWorkspace = (
  context: ServiceContext,
  request: CreateWorkspaceWithSessionRecord
): Workspace => {
  const workspaceId = canonicalUuid(request.workspace.id ?? randomUUID())
  const existing = readWorkspaceRow(context.sqlite, workspaceId)
  if (existing !== undefined) return workspaceFromRow(existing)
  return upsertWorkspaceRow(context, { ...request.workspace, id: workspaceId })
}

const existingOrNewSession = (
  context: ServiceContext,
  request: CreateWorkspaceWithSessionRecord,
  sessionId: string,
  workspace: Workspace
): SessionSummary => {
  if (sessionExists(context.sqlite, sessionId)) return context.getSession(sessionId)
  return insertSessionRow(context, { ...request.session, id: sessionId, workspaceId: workspace.id })
}

const sessionExists = (sqlite: ServiceContext["sqlite"], sessionId: string): boolean =>
  sqlite.prepare(creationSql.sessionId).get(sessionId) !== undefined

const creationSql = {
  sessionId: "select id from sessions where id = ?",
  setSessionWorkspace: "update sessions set workspace_id = ? where id = ?",
  deleteOtherSessionPanes:
    "delete from workspace_panes where id <> ? and resource_kind = 'session' and resource_id = ?",
  upsertSessionPane: `insert into workspace_panes (
                 id, workspace_id, provider_id, pane_type, title, resource_kind,
                 resource_id, metadata, revision, created_at, updated_at, position
               ) values (?, ?, 'codevisor', 'chat', ?, 'session', ?, null, 1, ?, null, ?)
               on conflict(id) do update set
                 position = case when workspace_panes.workspace_id = excluded.workspace_id
                   then workspace_panes.position else excluded.position end,
                 workspace_id = excluded.workspace_id,
                 provider_id = 'codevisor',
                 pane_type = 'chat',
                 title = excluded.title,
                 resource_kind = 'session',
                 resource_id = excluded.resource_id,
                 metadata = null,
                 revision = workspace_panes.revision + 1,
                 updated_at = ?`
}
