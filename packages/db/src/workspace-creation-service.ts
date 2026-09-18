import { randomUUID } from "node:crypto"

import { isoTimestamp } from "@codevisor/api"

import { attempt } from "./errors.js"
import { canonicalUuid } from "./ids.js"
import { workspaceFromRow, workspacePaneFromRow } from "./row-mappers.js"
import type { WorkspacePaneRow, WorkspaceRow } from "./rows.js"
import type { ServiceContext } from "./service-context.js"
import type { CodevisorDatabaseService } from "./service.js"
import { insertSessionRow } from "./sessions-service.js"
import { upsertWorkspaceRow } from "./workspaces-service.js"

/// A new workspace is born around its first chat. Writing the workspace, the
/// session and the chat pane in ONE transaction means the navigation journal
/// records them together, so no other client can ever observe a workspace
/// without its chat (the state that used to leave phantom placeholder tabs
/// behind). An existing workspace keeps its metadata: only membership and
/// the pane are added. Idempotent per session id so a retried request
/// converges.
export const makeWorkspaceCreationService = (
  context: ServiceContext
): Pick<CodevisorDatabaseService, "createWorkspaceWithSession"> => {
  const { sqlite, getSession } = context

  return {
    createWorkspaceWithSession: (request) =>
      attempt("createWorkspaceWithSession", () =>
        sqlite.transaction(() => {
          const workspaceId = canonicalUuid(request.workspace.id ?? randomUUID())
          const existingWorkspace = sqlite
            .prepare("select * from workspaces where id = ?")
            .get(workspaceId) as WorkspaceRow | undefined
          const workspace =
            existingWorkspace === undefined
              ? upsertWorkspaceRow(context, { ...request.workspace, id: workspaceId })
              : workspaceFromRow(existingWorkspace)
          const sessionId = canonicalUuid(request.session.id ?? randomUUID())
          const existing = sqlite.prepare("select id from sessions where id = ?").get(sessionId)
          const session =
            existing === undefined
              ? insertSessionRow(context, {
                  ...request.session,
                  id: sessionId,
                  workspaceId: workspace.id
                })
              : getSession(sessionId)
          if (session.projectId.toLowerCase() !== workspace.projectId.toLowerCase()) {
            throw new Error(
              `Session ${sessionId} and workspace ${workspace.id} belong to different projects`
            )
          }
          const now = isoTimestamp()
          const paneId = canonicalUuid(request.pane?.id ?? sessionId)
          const title = request.pane?.title ?? (session.title || "Chat")
          sqlite
            .prepare("update sessions set workspace_id = ? where id = ?")
            .run(workspace.id, sessionId)
          sqlite
            .prepare(
              "delete from workspace_panes where id <> ? and resource_kind = 'session' and resource_id = ?"
            )
            .run(paneId, sessionId)
          sqlite
            .prepare(
              `insert into workspace_panes (
                 id, workspace_id, provider_id, pane_type, title, resource_kind,
                 resource_id, metadata, revision, created_at, updated_at
               ) values (?, ?, 'codevisor', 'chat', ?, 'session', ?, null, 1, ?, null)
               on conflict(id) do update set
                 workspace_id = excluded.workspace_id,
                 provider_id = 'codevisor',
                 pane_type = 'chat',
                 title = excluded.title,
                 resource_kind = 'session',
                 resource_id = excluded.resource_id,
                 metadata = null,
                 revision = workspace_panes.revision + 1,
                 updated_at = ?`
            )
            .run(paneId, workspace.id, title, sessionId, session.createdAt, now)
          const pane = workspacePaneFromRow(
            sqlite
              .prepare("select * from workspace_panes where id = ?")
              .get(paneId) as WorkspacePaneRow
          )
          return { workspace, session: getSession(sessionId), pane }
        })()
      )
  }
}
