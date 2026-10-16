import { randomUUID } from "node:crypto"

import {
  initialWorkspacePosition,
  workspacePositionEpoch,
  isoTimestamp,
  type Workspace
} from "@codevisor/api"

import { attempt } from "./errors.js"
import { canonicalUuid } from "./ids.js"
import { reorderPanePositions } from "./pane-position.js"
import { serializeLabels, workspaceFromRow, workspacePaneFromRow } from "./row-mappers.js"
import { rowReader, text } from "./row-reader.js"
import { workspacePaneRows, workspaceRows } from "./rows.js"
import { archivedStamp, type ServiceContext } from "./service-context.js"
import type { CodevisorDatabaseService } from "./service.js"
import { makeSessionWorkspacesService } from "./session-workspaces-service.js"
import * as panes from "./workspace-pane-operations.js"
import type { UpsertWorkspaceRecord } from "./workspace-service-types.js"

const sidebarPositionRows = rowReader({ sidebar_position: text })

export const readWorkspaceRow = (sqlite: ServiceContext["sqlite"], id: string) =>
  workspaceRows.maybe(sqlite.prepare("select * from workspaces where id = ?").get(id))

const readWorkspace = (sqlite: ServiceContext["sqlite"], id: string): Workspace =>
  workspaceFromRow(
    workspaceRows.one(sqlite.prepare("select * from workspaces where id = ?").get(id))
  )

export const listWorkspaceRows = (sqlite: ServiceContext["sqlite"]) =>
  workspaceRows
    .all(sqlite.prepare("select * from workspaces order by sidebar_position, id").all())
    .map(workspaceFromRow)

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
  const head = sidebarPositionRows.maybe(
    sqlite
      .prepare("select sidebar_position from workspaces order by sidebar_position limit 1")
      .get()
  )
  const epoch = Math.max(
    Date.now(),
    head ? workspacePositionEpoch(head.sidebar_position) + 1 : 0,
    request.sidebarOrderHead ? workspacePositionEpoch(request.sidebarOrderHead) + 1 : 0
  )
  const position = existing?.sidebar_position ?? initialWorkspacePosition(epoch, id)
  const stamp = archivedStamp(
    request.isArchived,
    existing?.is_archived === 1,
    existing?.archived_at ?? undefined
  )
  sqlite
    .prepare(
      `insert into workspaces (
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
                 updated_at = ?`
    )
    .run(
      id,
      config.serverId,
      projectId,
      request.name,
      request.hasCustomName ? 1 : 0,
      request.rootDirectory ?? null,
      stamp === null ? 0 : 1,
      stamp,
      request.createdAt ?? now,
      position,
      serializeLabels(request.labels),
      request.botId === undefined ? null : canonicalUuid(request.botId),
      request.labels === undefined ? 0 : 1,
      now
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
        const wasArchived = existing.is_archived === 1
        const stamp = archivedStamp(
          request.isArchived,
          wasArchived,
          existing.archived_at ?? undefined
        )
        sqlite
          .prepare(
            `update workspaces set
               name = ?, has_custom_name = ?, root_directory = ?,
               is_archived = ?, archived_at = ?, updated_at = ?,
               sidebar_position = ?, sidebar_order_revision = ?,
               labels = case when ? then ? else labels end
             where id = ?`
          )
          .run(
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
          )
        return readWorkspace(sqlite, id)
      }),
    deleteWorkspace: (id) =>
      attempt("deleteWorkspace", () => {
        const result = sqlite.prepare("delete from workspaces where id = ?").run(canonicalUuid(id))
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
        const select = sqlite.prepare(
          "select * from workspace_panes where workspace_id = ? order by position, created_at, id"
        )
        return sqlite.transaction(() => {
          const currentPanes = workspacePaneRows.all(select.all(workspaceId))
          reorderPanePositions(sqlite, currentPanes, paneIds)
          return workspacePaneRows.all(select.all(workspaceId)).map(workspacePaneFromRow)
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
