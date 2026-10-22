import { randomUUID } from "node:crypto"

import {
  initialWorkspacePosition,
  workspacePositionEpoch,
  isoTimestamp,
  type UpdateWorkspaceRequest,
  type Workspace
} from "@codevisor/api"
import type Database from "better-sqlite3"

import { attempt } from "./errors.js"
import { canonicalUuid } from "./ids.js"
import { reorderPanePositions } from "./pane-position.js"
import { serializeLabels, workspaceFromRow, workspacePaneFromRow } from "./row-mappers.js"
import { rowReader, text } from "./row-reader.js"
import { workspacePaneRows, workspaceRows, type WorkspaceRow } from "./rows.js"
import { archivedStamp, type ServiceContext } from "./service-context.js"
import type { CodevisorDatabaseService } from "./service.js"
import { makeSessionWorkspacesService } from "./session-workspaces-service.js"
import * as panes from "./workspace-pane-operations.js"
import type { UpsertWorkspaceRecord } from "./workspace-service-types.js"

export const readWorkspaceRow = (sqlite: ServiceContext["sqlite"], id: string) =>
  workspaceRows.maybe(sqlite.prepare(workspaceSql.byId).get(id))

export const listWorkspaceRows = (sqlite: ServiceContext["sqlite"]) =>
  workspaceRows.all(sqlite.prepare(workspaceSql.list).all()).map(workspaceFromRow)

export const upsertWorkspaceRow = (
  context: ServiceContext,
  request: UpsertWorkspaceRecord
): Workspace => {
  const { sqlite, config, getProject } = context

  const projectId = canonicalUuid(request.projectId)
  getProject(projectId)
  const now = isoTimestamp()
  const id = (request.id ?? randomUUID()).toLowerCase()
  const existing = readWorkspaceRow(sqlite, id)
  const epoch = nextSidebarEpoch(headSidebarPosition(sqlite), request.sidebarOrderHead)
  const position =
    existing?.sidebar_position ?? request.sidebarPosition ?? initialWorkspacePosition(epoch, id)
  const stamp = archivedStamp(
    request.isArchived,
    existing?.is_archived === 1,
    existing?.archived_at ?? undefined
  )
  writeWorkspace(
    sqlite,
    { id, serverId: config.serverId, projectId, position, stamp, now },
    request
  )
  return readWorkspace(sqlite, id)
}

export const makeWorkspacesService = (
  context: ServiceContext
): Pick<
  CodevisorDatabaseService,
  | "listWorkspaces"
  | "upsertWorkspace"
  | "updateWorkspace"
  | "deleteWorkspace"
  | "getWorkspaceSnapshot"
  | "listWorkspacePanes"
  | "upsertWorkspacePane"
  | "updateWorkspacePane"
  | "reorderWorkspacePanes"
  | "deleteWorkspacePane"
  | "promoteWorkspacePaneToSession"
  | "setSessionWorkspace"
> => {
  const { sqlite } = context

  return {
    ...makeSessionWorkspacesService(context),
    listWorkspaces: attempt("listWorkspaces", () => listWorkspaceRows(sqlite)),
    upsertWorkspace: (request) =>
      attempt("upsertWorkspace", () => upsertWorkspaceRow(context, request)),
    updateWorkspace: (rawId, request) =>
      attempt("updateWorkspace", () => {
        const id = canonicalUuid(rawId)
        const existing = readWorkspaceRow(sqlite, id)
        if (existing === undefined) {
          throw new Error(`Workspace not found: ${id}`)
        }
        const stamp = archivedStamp(
          request.isArchived,
          existing.is_archived === 1,
          existing.archived_at ?? undefined
        )
        sqlite
          .prepare(workspaceSql.update)
          .run(...workspaceUpdateParams(id, existing, request, stamp))
        return readWorkspace(sqlite, id)
      }),
    deleteWorkspace: (id) =>
      attempt("deleteWorkspace", () => {
        const result = sqlite.prepare(workspaceSql.delete).run(canonicalUuid(id))
        if (result.changes === 0) {
          throw new Error(`Workspace not found: ${id}`)
        }
      }),
    getWorkspaceSnapshot: attempt("getWorkspaceSnapshot", () =>
      sqlite.transaction(() => ({
        workspaces: listWorkspaceRows(sqlite),
        panes: panes.listWorkspacePanes(sqlite)
      }))()
    ),
    listWorkspacePanes: attempt("listWorkspacePanes", () => panes.listWorkspacePanes(sqlite)),
    upsertWorkspacePane: (workspaceId, request) =>
      attempt("upsertWorkspacePane", () => panes.upsertWorkspacePane(sqlite, workspaceId, request)),
    updateWorkspacePane: (workspaceId, paneId, request) =>
      attempt("updateWorkspacePane", () =>
        panes.updateWorkspacePane(sqlite, workspaceId, paneId, request)
      ),
    reorderWorkspacePanes: (rawWorkspaceId, paneIds) =>
      attempt("reorderWorkspacePanes", () => {
        const workspaceId = canonicalUuid(rawWorkspaceId)
        const select = sqlite.prepare(orderedPanesSql)
        return sqlite.transaction(() => {
          const currentPanes = panesFrom(select, workspaceId)
          reorderPanePositions(sqlite, currentPanes, paneIds)
          return panesFrom(select, workspaceId).map(workspacePaneFromRow)
        })()
      }),
    deleteWorkspacePane: (workspaceId, paneId) =>
      attempt("deleteWorkspacePane", () => panes.deleteWorkspacePane(sqlite, workspaceId, paneId)),
    promoteWorkspacePaneToSession: (workspaceId, paneId, sessionId, title) =>
      attempt("promoteWorkspacePaneToSession", () =>
        panes.promoteWorkspacePaneToSession(sqlite, workspaceId, paneId, sessionId, title)
      )
  }
}

interface WorkspaceWrite {
  readonly id: string
  readonly serverId: string
  readonly projectId: string
  readonly position: string
  readonly stamp: string | null
  readonly now: string
}

const readWorkspace = (sqlite: ServiceContext["sqlite"], id: string): Workspace =>
  workspaceFromRow(workspaceRows.one(sqlite.prepare(workspaceSql.byId).get(id)))

const headSidebarPosition = (sqlite: ServiceContext["sqlite"]): string | undefined =>
  sidebarPositionRows.maybe(sqlite.prepare(workspaceSql.headPosition).get())?.sidebar_position

const nextSidebarEpoch = (head: string | undefined, requestedHead: string | undefined): number =>
  Math.max(
    Date.now(),
    head === undefined ? 0 : workspacePositionEpoch(head) + 1,
    requestedHead ? workspacePositionEpoch(requestedHead) + 1 : 0
  )

const writeWorkspace = (
  sqlite: ServiceContext["sqlite"],
  write: WorkspaceWrite,
  request: UpsertWorkspaceRecord
): void => {
  sqlite
    .prepare(workspaceSql.upsert)
    .run(
      write.id,
      write.serverId,
      write.projectId,
      request.name,
      request.hasCustomName ? 1 : 0,
      request.rootDirectory ?? null,
      write.stamp === null ? 0 : 1,
      write.stamp,
      request.createdAt ?? write.now,
      write.position,
      serializeLabels(request.labels),
      request.botId === undefined ? null : canonicalUuid(request.botId),
      request.labels === undefined ? 0 : 1,
      write.now
    )
}

const workspaceUpdateParams = (
  id: string,
  existing: WorkspaceRow,
  request: UpdateWorkspaceRequest,
  stamp: string | null
): ReadonlyArray<string | number | null> => [
  request.name ?? existing.name,
  (request.hasCustomName ?? existing.has_custom_name === 1) ? 1 : 0,
  request.rootDirectory ?? existing.root_directory,
  stamp === null ? 0 : 1,
  stamp,
  isoTimestamp(),
  request.sidebarOrder?.position ?? existing.sidebar_position,
  existing.sidebar_order_revision + (request.sidebarOrder === undefined ? 0 : 1),
  request.labels === undefined ? 0 : 1,
  serializeLabels(request.labels),
  id
]

const panesFrom = (select: Database.Statement, workspaceId: string) =>
  workspacePaneRows.all(select.all(workspaceId))

const sidebarPositionRows = rowReader({ sidebar_position: text })

const workspaceSql = {
  byId: "select * from workspaces where id = ?",
  list: "select * from workspaces order by sidebar_position, id",
  headPosition: "select sidebar_position from workspaces order by sidebar_position limit 1",
  upsert: `insert into workspaces (
                 id, server_id, project_id, name, has_custom_name,
                 root_directory, is_archived, archived_at, created_at, updated_at, sidebar_position,
                 labels, bot_id
               ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, null, ?, ?, ?)
               on conflict(id) do update set
                 project_id = excluded.project_id,
                 name = excluded.name,
                 has_custom_name = excluded.has_custom_name,
                 root_directory = excluded.root_directory,
                 is_archived = excluded.is_archived,
                 archived_at = excluded.archived_at,
                 labels = case when ? then excluded.labels else workspaces.labels end,
                 bot_id = coalesce(workspaces.bot_id, excluded.bot_id),
                 updated_at = ?`,
  update: `update workspaces set
               name = ?, has_custom_name = ?, root_directory = ?,
               is_archived = ?, archived_at = ?, updated_at = ?,
               sidebar_position = ?, sidebar_order_revision = ?,
               labels = case when ? then ? else labels end
             where id = ?`,
  delete: "delete from workspaces where id = ?"
}

const orderedPanesSql =
  "select * from workspace_panes where workspace_id = ? order by position, created_at, id"
