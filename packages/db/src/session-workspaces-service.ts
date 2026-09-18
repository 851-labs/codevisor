import { isoTimestamp } from "@codevisor/api"

import { attempt } from "./errors.js"
import { canonicalUuid } from "./ids.js"
import type { ServiceContext } from "./service-context.js"
import type { CodevisorDatabaseService } from "./service.js"

export const makeSessionWorkspacesService = (
  context: ServiceContext
): Pick<CodevisorDatabaseService, "setSessionWorkspace"> => {
  const { sqlite } = context

  return {
    setSessionWorkspace: (sessionId, workspaceId) =>
      attempt("setSessionWorkspace", () => {
        const id = canonicalUuid(sessionId)
        const targetWorkspaceId = workspaceId == null ? null : canonicalUuid(workspaceId)
        sqlite.transaction(() => {
          const result = sqlite
            .prepare("update sessions set workspace_id = ? where id = ?")
            .run(targetWorkspaceId, id)
          if (result.changes === 0) {
            throw new Error(`Session not found: ${sessionId}`)
          }
          // Membership and the chat's pane move together. Detaching deletes
          // the pane; a workspace left without panes is a valid state that
          // clients render with their own local empty page.
          if (targetWorkspaceId === null) {
            sqlite
              .prepare(
                "delete from workspace_panes where resource_kind = 'session' and resource_id = ?"
              )
              .run(id)
            return
          }
          const existing = sqlite
            .prepare(
              "select id from workspace_panes where resource_kind = 'session' and resource_id = ?"
            )
            .get(id) as { readonly id: string } | undefined
          if (existing !== undefined) {
            sqlite
              .prepare(
                "update workspace_panes set workspace_id = ?, revision = revision + 1, updated_at = ? where id = ?"
              )
              .run(targetWorkspaceId, isoTimestamp(), existing.id)
            return
          }
          const session = sqlite
            .prepare("select title, created_at from sessions where id = ?")
            .get(id) as {
            readonly title: string
            readonly created_at: string
          }
          sqlite
            .prepare(
              `insert into workspace_panes (
                 id, workspace_id, provider_id, pane_type, title,
                 resource_kind, resource_id, created_at
               ) values (?, ?, 'codevisor', 'chat', ?, 'session', ?, ?)`
            )
            .run(id, targetWorkspaceId, session.title || "Chat", id, session.created_at)
        })()
      })
  }
}
