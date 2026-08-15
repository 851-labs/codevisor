import { isoTimestamp } from "@codevisor/api"
import { randomUUID } from "node:crypto"
import { attempt } from "./errors.js"
import { canonicalUuid } from "./ids.js"
import { workspaceFromRow } from "./row-mappers.js"
import type { WorkspaceRow } from "./rows.js"
import type { CodevisorDatabaseService } from "./service.js"
import { archivedStamp, type ServiceContext } from "./service-context.js"

export const makeWorkspacesService = (
  context: ServiceContext
): Pick<
  CodevisorDatabaseService,
  | "listWorkspaces"
  | "upsertWorkspace"
  | "updateWorkspace"
  | "deleteWorkspace"
  | "setSessionWorkspace"
> => {
  const { sqlite, config, getProject } = context

  /// Same contract as the project cascade, one level down. Pane layout is kept
  /// (the workspace row survives) so restoring revives the surface intact.
  const cascadeArchiveWorkspace = (workspaceId: string, stamp: string): void => {
    sqlite
      .prepare(
        `update sessions set is_archived = 1, archived_at = ?, archive_cascade_from = ?
         where workspace_id = ? collate nocase and is_archived = 0`
      )
      .run(stamp, workspaceId, workspaceId)
  }

  const cascadeUnarchiveWorkspace = (workspaceId: string): void => {
    sqlite
      .prepare(
        `update sessions set is_archived = 0, archived_at = null, archive_cascade_from = null
         where workspace_id = ? collate nocase and archive_cascade_from = ? collate nocase`
      )
      .run(workspaceId, workspaceId)
  }

  return {
    listWorkspaces: attempt("listWorkspaces", () =>
      (
        sqlite
          .prepare("select * from workspaces order by created_at desc")
          .all() as ReadonlyArray<WorkspaceRow>
      ).map(workspaceFromRow)
    ),
    upsertWorkspace: (request) =>
      attempt("upsertWorkspace", () => {
        const projectId = canonicalUuid(request.projectId)
        getProject(projectId)
        const now = isoTimestamp()
        const id = (request.id ?? randomUUID()).toLowerCase()
        const existing = sqlite.prepare("select * from workspaces where id = ?").get(id) as
          | WorkspaceRow
          | undefined
        const stamp = archivedStamp(
          request.isArchived,
          existing?.is_archived === 1,
          existing?.archived_at ?? undefined
        )
        const wasArchived = existing?.is_archived === 1
        sqlite.transaction(() => {
          sqlite
            .prepare(
              `insert into workspaces (
                 id, server_id, project_id, name, has_custom_name, symbol_name,
                 root_directory, is_archived, archived_at, created_at, updated_at
               ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, null)
               on conflict(id) do update set
                 project_id = excluded.project_id,
                 name = excluded.name,
                 has_custom_name = excluded.has_custom_name,
                 symbol_name = excluded.symbol_name,
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
              request.symbolName ?? null,
              request.rootDirectory ?? null,
              stamp === null ? 0 : 1,
              stamp,
              request.createdAt ?? now,
              now
            )
          // A full upsert can flip the archive bit just like a PATCH, so it
          // owes the same cascade — otherwise archiving via PUT would leave
          // the workspace's chats visible under a hidden workspace.
          if (stamp !== null && !wasArchived) {
            cascadeArchiveWorkspace(id, stamp)
          } else if (stamp === null && wasArchived) {
            cascadeUnarchiveWorkspace(id)
          }
        })()
        return workspaceFromRow(
          sqlite.prepare("select * from workspaces where id = ?").get(id) as WorkspaceRow
        )
      }),
    updateWorkspace: (rawId, request) =>
      attempt("updateWorkspace", () => {
        const id = canonicalUuid(rawId)
        const existing = sqlite.prepare("select * from workspaces where id = ?").get(id) as
          | WorkspaceRow
          | undefined
        if (existing === undefined) {
          throw new Error(`Workspace not found: ${id}`)
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
        sqlite.transaction(() => {
          sqlite
            .prepare(
              `update workspaces set
                 name = ?, has_custom_name = ?, symbol_name = ?, root_directory = ?,
                 is_archived = ?, archived_at = ?, updated_at = ?
               where id = ?`
            )
            .run(
              request.name ?? existing.name,
              (request.hasCustomName ?? existing.has_custom_name === 1) ? 1 : 0,
              request.symbolName ?? existing.symbol_name,
              request.rootDirectory ?? existing.root_directory,
              stamp === null ? 0 : 1,
              stamp,
              isoTimestamp(),
              id
            )
          if (stamp !== null && !wasArchived) {
            cascadeArchiveWorkspace(id, stamp)
          } else if (stamp === null && wasArchived) {
            cascadeUnarchiveWorkspace(id)
          }
        })()
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
    setSessionWorkspace: (sessionId, workspaceId) =>
      attempt("setSessionWorkspace", () => {
        const result = sqlite
          .prepare("update sessions set workspace_id = ? where id = ?")
          .run(workspaceId == null ? null : canonicalUuid(workspaceId), canonicalUuid(sessionId))
        if (result.changes === 0) {
          throw new Error(`Session not found: ${sessionId}`)
        }
      })
  }
}
