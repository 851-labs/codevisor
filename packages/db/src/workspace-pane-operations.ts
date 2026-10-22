import { randomUUID } from "node:crypto"

import {
  isoTimestamp,
  type UpsertWorkspacePaneRequest,
  type UpdateWorkspacePaneRequest
} from "@codevisor/api"
import type Database from "better-sqlite3"

import { canonicalUuid } from "./ids.js"
import { workspacePaneFromRow } from "./row-mappers.js"
import { rowReader, text } from "./row-reader.js"
import { workspacePaneRows, type WorkspacePaneRow } from "./rows.js"
import {
  discardConflictingPanes,
  writePaneUpsert,
  writePaneUpdate,
  writePanePromotion,
  assignPaneSession
} from "./workspace-pane-writes.js"

const projectIdRows = rowReader({ project_id: text })

const sessionProjectRows = rowReader({ id: text, project_id: text })

export const readPane = (sqlite: Database.Database, id: string) =>
  workspacePaneFromRow(workspacePaneRows.one(sqlite.prepare(paneSql.byId).get(id)))

export const paneRow = (sqlite: Database.Database, id: string) =>
  workspacePaneRows.maybe(sqlite.prepare(paneSql.byId).get(id))

export const listWorkspacePanes = (sqlite: Database.Database) =>
  workspacePaneRows.all(sqlite.prepare(paneSql.ordered).all()).map(workspacePaneFromRow)

const upsertResourceId = (
  sqlite: Database.Database,
  workspaceId: string,
  id: string,
  request: UpsertWorkspacePaneRequest
) => {
  const existing = paneRow(sqlite, id)
  if (existing !== undefined && existing.workspace_id !== workspaceId) {
    throw new Error(`Pane ${id} belongs to workspace ${existing.workspace_id}`)
  }
  if ((request.resourceKind === undefined) !== (request.resourceId === undefined)) {
    throw new Error("resourceKind and resourceId must be provided together")
  }
  return request.resourceId === undefined ? null : canonicalUuid(request.resourceId)
}

export const upsertWorkspacePane = (
  sqlite: Database.Database,
  rawWorkspaceId: string,
  request: UpsertWorkspacePaneRequest
) => {
  const workspaceId = canonicalUuid(rawWorkspaceId)
  const id = canonicalUuid(request.id ?? randomUUID())
  const now = isoTimestamp()
  const resourceId = upsertResourceId(sqlite, workspaceId, id, request)
  sqlite.transaction(() => {
    const replacedPosition =
      request.resourceKind !== undefined && resourceId !== null
        ? discardConflictingPanes(sqlite, id, request.resourceKind, resourceId, workspaceId)
        : undefined
    writePaneUpsert(sqlite, workspaceId, id, request, resourceId, now, replacedPosition)
    assignPaneSession(sqlite, workspaceId, request.resourceKind, resourceId)
  })()
  return readPane(sqlite, id)
}

const requireScopedPane = (sqlite: Database.Database, workspaceId: string, paneId: string) => {
  const existing = workspacePaneRows.maybe(
    sqlite.prepare(paneSql.inWorkspace).get(paneId, workspaceId)
  )
  if (existing === undefined) {
    throw new Error(`Workspace pane not found: ${paneId}`)
  }
  return existing
}

const updatedResourceId = (existing: WorkspacePaneRow, request: UpdateWorkspacePaneRequest) => {
  if (request.resourceId === undefined) return existing.resource_id
  if (request.resourceId === null) return null
  return canonicalUuid(request.resourceId)
}

export const updateWorkspacePane = (
  sqlite: Database.Database,
  rawWorkspaceId: string,
  rawPaneId: string,
  request: UpdateWorkspacePaneRequest
) => {
  const workspaceId = canonicalUuid(rawWorkspaceId)
  const paneId = canonicalUuid(rawPaneId)
  const existing = requireScopedPane(sqlite, workspaceId, paneId)
  const resourceKind =
    request.resourceKind === undefined ? existing.resource_kind : request.resourceKind
  const resourceId = updatedResourceId(existing, request)
  if ((resourceKind === null) !== (resourceId === null)) {
    throw new Error("resourceKind and resourceId must be provided together")
  }
  const keepTerminalStatus =
    existing.resource_kind === resourceKind &&
    existing.resource_id?.toLowerCase() === resourceId?.toLowerCase()
      ? 1
      : 0
  sqlite.transaction(() => {
    if (resourceKind !== null && resourceId !== null) {
      discardConflictingPanes(sqlite, paneId, resourceKind, resourceId, workspaceId)
    }
    writePaneUpdate(
      sqlite,
      workspaceId,
      paneId,
      request,
      existing,
      resourceKind,
      resourceId,
      keepTerminalStatus
    )
    assignPaneSession(sqlite, workspaceId, resourceKind, resourceId)
  })()
  return readPane(sqlite, paneId)
}

export const deleteWorkspacePane = (
  sqlite: Database.Database,
  rawWorkspaceId: string,
  rawPaneId: string
): void => {
  const workspaceId = canonicalUuid(rawWorkspaceId)
  const paneId = canonicalUuid(rawPaneId)
  if (!workspaceExists(sqlite, workspaceId)) throw new Error(`Workspace not found: ${workspaceId}`)
  sqlite.prepare(paneSql.delete).run(paneId, workspaceId)
}

const validatePromotion = (
  sqlite: Database.Database,
  workspaceId: string,
  paneId: string,
  sessionId: string
): void => {
  if (!paneExists(sqlite, workspaceId, paneId)) {
    throw new Error(`Workspace pane not found: ${paneId}`)
  }
  const workspace = workspaceProject(sqlite, workspaceId)
  const session = sessionProject(sqlite, sessionId)
  if (session === undefined) throw new Error(`Session not found: ${sessionId}`)
  /* v8 ignore next */
  if (workspace === undefined) throw new Error(`Workspace not found: ${workspaceId}`)
  if (session.project_id !== workspace.project_id) {
    throw new Error(
      `Session ${sessionId} and workspace ${workspaceId} belong to different projects`
    )
  }
}

export const promoteWorkspacePaneToSession = (
  sqlite: Database.Database,
  rawWorkspaceId: string,
  rawPaneId: string,
  rawSessionId: string,
  title: string
) => {
  const workspaceId = canonicalUuid(rawWorkspaceId)
  const paneId = canonicalUuid(rawPaneId)
  const sessionId = canonicalUuid(rawSessionId)
  sqlite.transaction(() => {
    validatePromotion(sqlite, workspaceId, paneId, sessionId)
    discardConflictingPanes(sqlite, paneId, "session", sessionId, workspaceId)
    writePanePromotion(sqlite, workspaceId, paneId, sessionId, title)
    assignPaneSession(sqlite, workspaceId, "session", sessionId)
  })()
  return readPane(sqlite, paneId)
}

const workspaceExists = (sqlite: Database.Database, workspaceId: string): boolean =>
  sqlite.prepare(paneSql.workspaceId).get(workspaceId) !== undefined

const paneExists = (sqlite: Database.Database, workspaceId: string, paneId: string): boolean =>
  sqlite.prepare(paneSql.idInWorkspace).get(paneId, workspaceId) !== undefined

const workspaceProject = (sqlite: Database.Database, workspaceId: string) =>
  projectIdRows.maybe(sqlite.prepare(paneSql.workspaceProject).get(workspaceId))

const sessionProject = (sqlite: Database.Database, sessionId: string) =>
  sessionProjectRows.maybe(sqlite.prepare(paneSql.sessionProject).get(sessionId))

const paneSql = {
  byId: "select * from workspace_panes where id = ?",
  ordered: "select * from workspace_panes order by position, created_at, id",
  inWorkspace: "select * from workspace_panes where id = ? and workspace_id = ?",
  idInWorkspace: "select id from workspace_panes where id = ? and workspace_id = ?",
  delete: "delete from workspace_panes where id = ? and workspace_id = ?",
  workspaceId: "select id from workspaces where id = ?",
  workspaceProject: "select project_id from workspaces where id = ?",
  sessionProject: "select id, project_id from sessions where id = ?"
}
