import { isoTimestamp } from "@codevisor/api"
import type { UpdateWorkspacePaneRequest, UpsertWorkspacePaneRequest } from "@codevisor/api"
import type Database from "better-sqlite3"

import { nextPanePositionIn } from "./pane-position.js"
import type { WorkspacePaneRow } from "./rows.js"

/// Delete competing resource panes inside the caller's write transaction.
/// Returns the tab slot of the pane it replaced in the target workspace, if
/// any.
export const discardConflictingPanes = (
  sqlite: Database.Database,
  paneId: string,
  resourceKind: string,
  resourceId: string,
  targetWorkspaceId: string
): string | undefined => {
  const replaced = sqlite
    .prepare(
      `select min(position) as position from workspace_panes
         where id <> ? and resource_kind = ? and resource_id = ? and workspace_id = ?
           and position <> ''`
    )
    .get(paneId, resourceKind, resourceId, targetWorkspaceId) as
    | { readonly position: string | null }
    | undefined
  sqlite
    .prepare(
      `delete from workspace_panes
         where id <> ? and resource_kind = ? and resource_id = ?
           and (workspace_id = ? or ? = 'session')`
    )
    .run(paneId, resourceKind, resourceId, targetWorkspaceId, resourceKind)
  return replaced?.position ?? undefined
}

/// Preserve terminal status only when the upsert keeps the same resource.
const sameResource = `workspace_panes.resource_kind is excluded.resource_kind
  and lower(workspace_panes.resource_id) is lower(excluded.resource_id)`

const contentChanged = (request: UpdateWorkspacePaneRequest): boolean =>
  request.position === undefined ||
  Object.entries(request).some(([key, value]) => key !== "position" && value !== undefined)

const paneUpsertSql = `insert into workspace_panes (
                 id, workspace_id, provider_id, pane_type, title, resource_kind,
                 resource_id, metadata, revision, created_at, updated_at, position
               ) values (?, ?, ?, ?, ?, ?, ?, ?, 1, ?, null, ?)
               on conflict(id) do update set
                 provider_id = excluded.provider_id,
                 pane_type = excluded.pane_type,
                 title = excluded.title,
                 resource_kind = excluded.resource_kind,
                 resource_id = excluded.resource_id,
                 metadata = excluded.metadata,
                 -- A live title and activity belong to the terminal the pane
                 -- showed.
                 live_title = case when ${sameResource} then workspace_panes.live_title end,
                 terminal_activity = case
                   when ${sameResource} then workspace_panes.terminal_activity
                 end,
                 revision = workspace_panes.revision + 1,
                 updated_at = ?
               where workspace_panes.provider_id is not excluded.provider_id
                  or workspace_panes.pane_type is not excluded.pane_type
                  or workspace_panes.title is not excluded.title
                  or workspace_panes.resource_kind is not excluded.resource_kind
                  or workspace_panes.resource_id is not excluded.resource_id
                  or workspace_panes.metadata is not excluded.metadata`

export const writePaneUpsert = (
  sqlite: Database.Database,
  workspaceId: string,
  id: string,
  request: UpsertWorkspacePaneRequest,
  resourceId: string | null,
  now: string,
  replacedPosition?: string
): void => {
  sqlite
    .prepare(paneUpsertSql)
    .run(
      id,
      workspaceId,
      request.providerId,
      request.paneType,
      request.title,
      request.resourceKind ?? null,
      resourceId,
      request.metadata ?? null,
      request.createdAt ?? now,
      replacedPosition ?? nextPanePositionIn(sqlite, workspaceId, id),
      now
    )
}

const paneUpdateSql = `update workspace_panes set
                 provider_id = ?, pane_type = ?, title = ?, resource_kind = ?,
                 resource_id = ?, metadata = ?, position = ?,
                 revision = revision + case when ? then 1 else 0 end, updated_at = ?,
                 live_title = case when ? then live_title end,
                 terminal_activity = case when ? then terminal_activity end
               where id = ? and workspace_id = ?`

export const writePaneUpdate = (
  sqlite: Database.Database,
  workspaceId: string,
  paneId: string,
  request: UpdateWorkspacePaneRequest,
  existing: WorkspacePaneRow,
  resourceKind: string | null,
  resourceId: string | null,
  keepTerminalStatus: number
): void => {
  sqlite
    .prepare(paneUpdateSql)
    .run(
      request.providerId ?? existing.provider_id,
      request.paneType ?? existing.pane_type,
      request.title ?? existing.title,
      resourceKind,
      resourceId,
      request.metadata === undefined ? existing.metadata : request.metadata,
      request.position ?? existing.position,
      contentChanged(request) ? 1 : 0,
      isoTimestamp(),
      keepTerminalStatus,
      keepTerminalStatus,
      paneId,
      workspaceId
    )
}

const panePromotionSql = `update workspace_panes set
                 provider_id = 'codevisor', pane_type = 'chat', title = ?,
                 resource_kind = 'session', resource_id = ?, metadata = null, live_title = null,
                 terminal_activity = null,
                 revision = revision + 1, updated_at = ?
               where id = ? and workspace_id = ?`

export const writePanePromotion = (
  sqlite: Database.Database,
  workspaceId: string,
  paneId: string,
  sessionId: string,
  title: string
): void => {
  sqlite.prepare(panePromotionSql).run(title, sessionId, isoTimestamp(), paneId, workspaceId)
}

export const assignPaneSession = (
  sqlite: Database.Database,
  workspaceId: string,
  resourceKind: string | null | undefined,
  resourceId: string | null
): void => {
  if (resourceKind === "session" && resourceId !== null) {
    sqlite.prepare("update sessions set workspace_id = ? where id = ?").run(workspaceId, resourceId)
  }
}
