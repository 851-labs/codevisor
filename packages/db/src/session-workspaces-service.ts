import { isoTimestamp } from "@codevisor/api"

import { attempt } from "./errors.js"
import { canonicalUuid } from "./ids.js"
import { nextPanePositionIn } from "./pane-position.js"
import { rowReader, text } from "./row-reader.js"
import type { ServiceContext } from "./service-context.js"
import type { CodevisorDatabaseService } from "./service.js"

const sessionTitleRows = rowReader({ title: text, created_at: text })

const sessionPaneRows = rowReader({ id: text, workspace_id: text })

function writeSessionMembership(
  sqlite: ServiceContext["sqlite"],
  id: string,
  targetWorkspaceId: string | null,
  sessionId: string
): void {
  const result = sqlite.prepare(sessionPaneSql.setWorkspace).run(targetWorkspaceId, id)
  if (result.changes === 0) {
    throw new Error(`Session not found: ${sessionId}`)
  }
}

function removeSessionPane(sqlite: ServiceContext["sqlite"], id: string): void {
  sqlite.prepare(sessionPaneSql.delete).run(id)
}

function moveSessionPane(
  sqlite: ServiceContext["sqlite"],
  targetWorkspaceId: string,
  existing: { readonly id: string; readonly workspace_id: string }
): void {
  sqlite
    .prepare(sessionPaneSql.move)
    .run(
      targetWorkspaceId,
      nextPanePositionIn(sqlite, targetWorkspaceId, existing.id),
      isoTimestamp(),
      existing.id
    )
}

function createSessionPane(
  sqlite: ServiceContext["sqlite"],
  id: string,
  targetWorkspaceId: string
): void {
  const session = sessionTitleAndCreation(sqlite, id)
  sqlite
    .prepare(sessionPaneSql.insert)
    .run(
      id,
      targetWorkspaceId,
      session.title || "Chat",
      id,
      session.created_at,
      nextPanePositionIn(sqlite, targetWorkspaceId, id)
    )
}

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
          writeSessionMembership(sqlite, id, targetWorkspaceId, sessionId)
          if (targetWorkspaceId === null) {
            removeSessionPane(sqlite, id)
            return
          }
          const existing = existingSessionPane(sqlite, id)
          if (existing?.workspace_id === targetWorkspaceId) return
          if (existing !== undefined) {
            moveSessionPane(sqlite, targetWorkspaceId, existing)
            return
          }
          createSessionPane(sqlite, id, targetWorkspaceId)
        })()
      })
  }
}

const sessionTitleAndCreation = (sqlite: ServiceContext["sqlite"], id: string) =>
  sessionTitleRows.one(sqlite.prepare(sessionPaneSql.sessionTitle).get(id))

const existingSessionPane = (sqlite: ServiceContext["sqlite"], sessionId: string) =>
  sessionPaneRows.maybe(sqlite.prepare(sessionPaneSql.bySession).get(sessionId))

const sessionPaneSql = {
  setWorkspace: "update sessions set workspace_id = ? where id = ?",
  delete: "delete from workspace_panes where resource_kind = 'session' and resource_id = ?",
  move: "update workspace_panes set workspace_id = ?, position = ?, revision = revision + 1, updated_at = ? where id = ?",
  sessionTitle: "select title, created_at from sessions where id = ?",
  insert: `insert into workspace_panes (
                 id, workspace_id, provider_id, pane_type, title,
                 resource_kind, resource_id, created_at, position
               ) values (?, ?, 'codevisor', 'chat', ?, 'session', ?, ?, ?)`,
  bySession:
    "select id, workspace_id from workspace_panes where resource_kind = 'session' and resource_id = ?"
}
