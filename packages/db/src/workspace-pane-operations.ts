import { randomUUID } from "node:crypto"

import {
  isoTimestamp,
  type UpsertWorkspacePaneRequest,
  type UpdateWorkspacePaneRequest
} from "@codevisor/api"
import type Database from "better-sqlite3"

import { canonicalUuid } from "./ids.js"
import { workspacePaneFromRow } from "./row-mappers.js"
import type { WorkspacePaneRow } from "./rows.js"
import {
  discardConflictingPanes,
  writePaneUpsert,
  writePaneUpdate,
  writePanePromotion,
  assignPaneSession
} from "./workspace-pane-writes.js"

const readPane = (sqlite: Database.Database, id: string) =>
  workspacePaneFromRow(
    sqlite.prepare("select * from workspace_panes where id = ?").get(id) as WorkspacePaneRow
  )

export const listWorkspacePanes = (sqlite: Database.Database) =>
  (
    sqlite
      .prepare("select * from workspace_panes order by position, created_at, id")
      .all() as ReadonlyArray<WorkspacePaneRow>
  ).map(workspacePaneFromRow)

const upsertResourceId = (
  sqlite: Database.Database,
  workspaceId: string,
  id: string,
  request: UpsertWorkspacePaneRequest
) => {
  const existing = sqlite.prepare("select * from workspace_panes where id = ?").get(id) as
    | WorkspacePaneRow
    | undefined
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
    if (request.resourceKind !== undefined && resourceId !== null) {
      // The explicit client pane wins over a legacy session-id pane,
      // preserving its stable identity during placeholder conversion.
      discardConflictingPanes(sqlite, id, request.resourceKind, resourceId, workspaceId)
    }
    writePaneUpsert(sqlite, workspaceId, id, request, resourceId, now)
    assignPaneSession(sqlite, workspaceId, request.resourceKind, resourceId)
  })()
  return readPane(sqlite, id)
}

const requireScopedPane = (sqlite: Database.Database, workspaceId: string, paneId: string) => {
  const existing = sqlite
    .prepare("select * from workspace_panes where id = ? and workspace_id = ?")
    .get(paneId, workspaceId) as WorkspacePaneRow | undefined
  if (existing === undefined) {
    throw new Error(`Workspace pane not found: ${paneId}`)
  }
  return existing
}

const updatedResourceId = (existing: WorkspacePaneRow, request: UpdateWorkspacePaneRequest) =>
  request.resourceId === undefined
    ? existing.resource_id
    : request.resourceId === null
      ? null
      : canonicalUuid(request.resourceId)

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
  const workspace = sqlite.prepare("select id from workspaces where id = ?").get(workspaceId)
  if (workspace === undefined) throw new Error(`Workspace not found: ${workspaceId}`)
  // Retrying a close is complete. Closing the last pane leaves an empty
  // workspace; clients render their own local empty page.
  sqlite
    .prepare("delete from workspace_panes where id = ? and workspace_id = ?")
    .run(paneId, workspaceId)
}

const validatePromotion = (
  sqlite: Database.Database,
  workspaceId: string,
  paneId: string,
  sessionId: string
): void => {
  const pane = sqlite
    .prepare("select id from workspace_panes where id = ? and workspace_id = ?")
    .get(paneId, workspaceId)
  if (pane === undefined) throw new Error(`Workspace pane not found: ${paneId}`)
  const workspace = sqlite
    .prepare("select project_id from workspaces where id = ?")
    .get(workspaceId) as { readonly project_id: string } | undefined
  const session = sqlite
    .prepare("select id, project_id from sessions where id = ?")
    .get(sessionId) as { readonly id: string; readonly project_id: string } | undefined
  if (session === undefined) throw new Error(`Session not found: ${sessionId}`)
  // The pane's foreign key makes this unreachable unless SQLite's
  // integrity guarantees are disabled or the database is corrupt.
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
    // Replace the globally unique compatibility pane and this placeholder
    // in the same transaction.
    discardConflictingPanes(sqlite, paneId, "session", sessionId, workspaceId)
    writePanePromotion(sqlite, workspaceId, paneId, sessionId, title)
    assignPaneSession(sqlite, workspaceId, "session", sessionId)
  })()
  return readPane(sqlite, paneId)
}
