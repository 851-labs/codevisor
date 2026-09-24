import { randomUUID } from "node:crypto"

import {
  initialWorkspacePosition,
  workspacePositionEpoch,
  isoTimestamp,
  type UpsertWorkspaceRequest,
  type Workspace
} from "@codevisor/api"

import { attempt } from "./errors.js"
import { canonicalUuid } from "./ids.js"
import { workspaceFromRow, workspacePaneFromRow } from "./row-mappers.js"
import type { WorkspacePaneRow, WorkspaceRow } from "./rows.js"
import { archivedStamp, type ServiceContext } from "./service-context.js"
import type { CodevisorDatabaseService } from "./service.js"
import { makeSessionWorkspacesService } from "./session-workspaces-service.js"

/// The synchronous upsert behind `upsertWorkspace`, exported so the atomic
/// workspace create can run it inside its own transaction.
export const upsertWorkspaceRow = (
  context: ServiceContext,
  request: UpsertWorkspaceRequest
): Workspace => {
  const { sqlite, config, getProject } = context

  const projectId = canonicalUuid(request.projectId)
  getProject(projectId)
  const now = isoTimestamp()
  const id = (request.id ?? randomUUID()).toLowerCase()
  const existing = sqlite.prepare("select * from workspaces where id = ?").get(id) as
    | WorkspaceRow
    | undefined
  const head = sqlite
    .prepare("select sidebar_position from workspaces order by sidebar_position limit 1")
    .get() as { sidebar_position: string } | undefined
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
                 root_directory, is_archived, archived_at, created_at, updated_at, sidebar_position
               ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, null, ?)
               on conflict(id) do update set
                 project_id = excluded.project_id,
                 name = excluded.name,
                 has_custom_name = excluded.has_custom_name,
                 root_directory = excluded.root_directory,
                 is_archived = excluded.is_archived,
                 archived_at = excluded.archived_at,
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
      now
    )
  return workspaceFromRow(
    sqlite.prepare("select * from workspaces where id = ?").get(id) as WorkspaceRow
  )
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
  | "deleteWorkspacePane"
  | "promoteWorkspacePaneToSession"
  | "setSessionWorkspace"
> => {
  const { sqlite } = context

  /// Removes every other pane rendering the same resource. A session is
  /// globally unique, so the pane that previously showed it goes away even
  /// when it was its workspace's last pane: an empty workspace is a valid
  /// state that clients render with their own local empty page.
  const discardConflictingPanes = (
    paneId: string,
    resourceKind: string,
    resourceId: string,
    targetWorkspaceId: string
  ): void => {
    sqlite
      .prepare(
        `delete from workspace_panes
         where id <> ? and resource_kind = ? and resource_id = ?
           and (workspace_id = ? or ? = 'session')`
      )
      .run(paneId, resourceKind, resourceId, targetWorkspaceId, resourceKind)
  }

  return {
    ...makeSessionWorkspacesService(context),
    listWorkspaces: attempt("listWorkspaces", () =>
      (
        sqlite
          .prepare("select * from workspaces order by sidebar_position, id")
          .all() as ReadonlyArray<WorkspaceRow>
      ).map(workspaceFromRow)
    ),
    upsertWorkspace: (request) =>
      attempt("upsertWorkspace", () => upsertWorkspaceRow(context, request)),
    updateWorkspace: (rawId, request) =>
      attempt("updateWorkspace", () => {
        const id = canonicalUuid(rawId)
        const existing = sqlite.prepare("select * from workspaces where id = ?").get(id) as
          | WorkspaceRow
          | undefined
        if (existing === undefined) {
          throw new Error(`Workspace not found: ${id}`)
        }
        if (
          request.sidebarOrder !== undefined &&
          request.sidebarOrder.expectedRevision !== existing.sidebar_order_revision
        ) {
          return workspaceFromRow(existing)
        }
        const wasArchived = existing.is_archived === 1
        // `archivedStamp` returns a moment exactly when the row ends up
        // archived, so the stamp doubles as the archived flag — deriving both
        // from it keeps them from ever disagreeing.
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
               sidebar_position = ?, sidebar_order_revision = ?
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
            id
          )
        return workspaceFromRow(
          sqlite.prepare("select * from workspaces where id = ?").get(id) as WorkspaceRow
        )
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
        workspaces: (
          sqlite
            .prepare("select * from workspaces order by sidebar_position, id")
            .all() as ReadonlyArray<WorkspaceRow>
        ).map(workspaceFromRow),
        panes: (
          sqlite
            .prepare("select * from workspace_panes order by created_at, id")
            .all() as ReadonlyArray<WorkspacePaneRow>
        ).map(workspacePaneFromRow)
      }))()
    ),
    listWorkspacePanes: attempt("listWorkspacePanes", () =>
      (
        sqlite
          .prepare("select * from workspace_panes order by created_at, id")
          .all() as ReadonlyArray<WorkspacePaneRow>
      ).map(workspacePaneFromRow)
    ),
    upsertWorkspacePane: (rawWorkspaceId, request) =>
      attempt("upsertWorkspacePane", () => {
        const workspaceId = canonicalUuid(rawWorkspaceId)
        const id = canonicalUuid(request.id ?? randomUUID())
        const now = isoTimestamp()
        const existing = sqlite.prepare("select * from workspace_panes where id = ?").get(id) as
          | WorkspacePaneRow
          | undefined
        if (existing !== undefined && existing.workspace_id !== workspaceId) {
          throw new Error(`Pane ${id} belongs to workspace ${existing.workspace_id}`)
        }
        if ((request.resourceKind === undefined) !== (request.resourceId === undefined)) {
          throw new Error("resourceKind and resourceId must be provided together")
        }
        const resourceId =
          request.resourceId === undefined ? null : canonicalUuid(request.resourceId)
        sqlite.transaction(() => {
          if (request.resourceKind !== undefined && resourceId !== null) {
            // A local legacy chat id may race the canonical session-id pane
            // created for an older client. The explicit client pane wins so
            // placeholder conversion preserves its stable identity.
            discardConflictingPanes(id, request.resourceKind, resourceId, workspaceId)
          }
          sqlite
            .prepare(
              `insert into workspace_panes (
                 id, workspace_id, provider_id, pane_type, title, resource_kind,
                 resource_id, metadata, revision, created_at, updated_at
               ) values (?, ?, ?, ?, ?, ?, ?, ?, 1, ?, null)
               on conflict(id) do update set
                 provider_id = excluded.provider_id,
                 pane_type = excluded.pane_type,
                 title = excluded.title,
                 resource_kind = excluded.resource_kind,
                 resource_id = excluded.resource_id,
                 metadata = excluded.metadata,
                 revision = workspace_panes.revision + 1,
                 updated_at = ?
               where workspace_panes.provider_id is not excluded.provider_id
                  or workspace_panes.pane_type is not excluded.pane_type
                  or workspace_panes.title is not excluded.title
                  or workspace_panes.resource_kind is not excluded.resource_kind
                  or workspace_panes.resource_id is not excluded.resource_id
                  or workspace_panes.metadata is not excluded.metadata`
            )
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
              now
            )
          if (request.resourceKind === "session" && resourceId !== null) {
            sqlite
              .prepare("update sessions set workspace_id = ? where id = ?")
              .run(workspaceId, resourceId)
          }
        })()
        return workspacePaneFromRow(
          sqlite.prepare("select * from workspace_panes where id = ?").get(id) as WorkspacePaneRow
        )
      }),
    updateWorkspacePane: (rawWorkspaceId, rawPaneId, request) =>
      attempt("updateWorkspacePane", () => {
        const workspaceId = canonicalUuid(rawWorkspaceId)
        const paneId = canonicalUuid(rawPaneId)
        const existing = sqlite
          .prepare("select * from workspace_panes where id = ? and workspace_id = ?")
          .get(paneId, workspaceId) as WorkspacePaneRow | undefined
        if (existing === undefined) {
          throw new Error(`Workspace pane not found: ${paneId}`)
        }
        const resourceKind =
          request.resourceKind === undefined ? existing.resource_kind : request.resourceKind
        const resourceId =
          request.resourceId === undefined
            ? existing.resource_id
            : request.resourceId === null
              ? null
              : canonicalUuid(request.resourceId)
        if ((resourceKind === null) !== (resourceId === null)) {
          throw new Error("resourceKind and resourceId must be provided together")
        }
        sqlite.transaction(() => {
          if (resourceKind !== null && resourceId !== null) {
            discardConflictingPanes(paneId, resourceKind, resourceId, workspaceId)
          }
          sqlite
            .prepare(
              `update workspace_panes set
                 provider_id = ?, pane_type = ?, title = ?, resource_kind = ?,
                 resource_id = ?, metadata = ?, revision = revision + 1, updated_at = ?
               where id = ? and workspace_id = ?`
            )
            .run(
              request.providerId ?? existing.provider_id,
              request.paneType ?? existing.pane_type,
              request.title ?? existing.title,
              resourceKind,
              resourceId,
              request.metadata === undefined ? existing.metadata : request.metadata,
              isoTimestamp(),
              paneId,
              workspaceId
            )
          if (resourceKind === "session" && resourceId !== null) {
            sqlite
              .prepare("update sessions set workspace_id = ? where id = ?")
              .run(workspaceId, resourceId)
          }
        })()
        return workspacePaneFromRow(
          sqlite
            .prepare("select * from workspace_panes where id = ?")
            .get(paneId) as WorkspacePaneRow
        )
      }),
    deleteWorkspacePane: (rawWorkspaceId, rawPaneId) =>
      attempt("deleteWorkspacePane", () => {
        const workspaceId = canonicalUuid(rawWorkspaceId)
        const paneId = canonicalUuid(rawPaneId)
        const workspace = sqlite.prepare("select id from workspaces where id = ?").get(workspaceId)
        if (workspace === undefined) throw new Error(`Workspace not found: ${workspaceId}`)
        // Keyed by the stable pane id, so a retry after a successful deletion
        // is already complete. Closing the last pane leaves the workspace
        // empty: the registry never holds a placeholder row for that state,
        // every client renders its own local empty page instead.
        sqlite
          .prepare("delete from workspace_panes where id = ? and workspace_id = ?")
          .run(paneId, workspaceId)
      }),
    promoteWorkspacePaneToSession: (rawWorkspaceId, rawPaneId, rawSessionId, title) =>
      attempt("promoteWorkspacePaneToSession", () => {
        const workspaceId = canonicalUuid(rawWorkspaceId)
        const paneId = canonicalUuid(rawPaneId)
        const sessionId = canonicalUuid(rawSessionId)
        sqlite.transaction(() => {
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

          // Session resources are globally unique. Removing a compatibility
          // pane and converting this exact placeholder happen in this same
          // transaction, so observers can only see the final one-pane state.
          discardConflictingPanes(paneId, "session", sessionId, workspaceId)
          sqlite
            .prepare(
              `update workspace_panes set
                 provider_id = 'codevisor', pane_type = 'chat', title = ?,
                 resource_kind = 'session', resource_id = ?, metadata = null,
                 revision = revision + 1, updated_at = ?
               where id = ? and workspace_id = ?`
            )
            .run(title, sessionId, isoTimestamp(), paneId, workspaceId)
          sqlite
            .prepare("update sessions set workspace_id = ? where id = ?")
            .run(workspaceId, sessionId)
        })()
        return workspacePaneFromRow(
          sqlite
            .prepare("select * from workspace_panes where id = ?")
            .get(paneId) as WorkspacePaneRow
        )
      })
  }
}
