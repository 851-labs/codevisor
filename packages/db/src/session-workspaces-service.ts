import { isoTimestamp } from "@codevisor/api"
import { randomUUID } from "node:crypto"
import { attempt } from "./errors.js"
import { canonicalUuid } from "./ids.js"
import type { CodevisorDatabaseService } from "./service.js"
import type { ServiceContext } from "./service-context.js"

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
          if (targetWorkspaceId === null) {
            const pane = sqlite
              .prepare(
                "select id, workspace_id from workspace_panes where resource_kind = 'session' and resource_id = ?"
              )
              .get(id) as { readonly id: string; readonly workspace_id: string } | undefined
            if (pane !== undefined) {
              const count = (
                sqlite
                  .prepare("select count(*) as count from workspace_panes where workspace_id = ?")
                  .get(pane.workspace_id) as { readonly count: number }
              ).count
              if (count > 1) {
                sqlite.prepare("delete from workspace_panes where id = ?").run(pane.id)
              } else {
                sqlite
                  .prepare(
                    `update workspace_panes set
                       provider_id = 'codevisor', pane_type = 'new-tab', title = 'New tab',
                       resource_kind = null, resource_id = null, metadata = null,
                       revision = revision + 1, updated_at = ?
                     where id = ?`
                  )
                  .run(isoTimestamp(), pane.id)
              }
            }
            return
          }
          const existing = sqlite
            .prepare(
              "select id from workspace_panes where resource_kind = 'session' and resource_id = ?"
            )
            .get(id) as { readonly id: string } | undefined
          if (existing !== undefined) {
            const existingPane = sqlite
              .prepare("select workspace_id from workspace_panes where id = ?")
              .get(existing.id) as { readonly workspace_id: string }
            if (existingPane.workspace_id !== targetWorkspaceId) {
              const sourceCount = (
                sqlite
                  .prepare("select count(*) as count from workspace_panes where workspace_id = ?")
                  .get(existingPane.workspace_id) as { readonly count: number }
              ).count
              if (sourceCount === 1) {
                const replacementId = randomUUID().toLowerCase()
                sqlite
                  .prepare(
                    `insert into workspace_panes (
                       id, workspace_id, provider_id, pane_type, title,
                       resource_kind, resource_id, metadata, revision, created_at, updated_at
                     ) values (?, ?, 'codevisor', 'new-tab', 'New tab', null, null, null, 1, ?, null)`
                  )
                  .run(replacementId, existingPane.workspace_id, isoTimestamp())
              }
            }
            sqlite
              .prepare(
                "update workspace_panes set workspace_id = ?, revision = revision + 1, updated_at = ? where id = ?"
              )
              .run(targetWorkspaceId, isoTimestamp(), existing.id)
          } else {
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
          }
        })()
      })
  }
}
