import type Database from "better-sqlite3"

import { rowReader, text } from "./row-reader.js"
import { projectSessionSidebarState } from "./session-sidebar-state.js"

export const retireSessionTurn = (
  sqlite: Database.Database,
  sessionId: string,
  changedAt: string
): void => {
  sqlite.prepare(retireSql.endTurn).run(sessionId)
  projectSessionSidebarState(sqlite, sessionId, changedAt)
}

export const retireWorkspaceTurns = (
  sqlite: Database.Database,
  workspaceId: string,
  changedAt: string
): void => {
  for (const sessionId of workspaceSessionIds(sqlite, workspaceId)) {
    retireSessionTurn(sqlite, sessionId, changedAt)
  }
}

const workspaceSessionIds = (sqlite: Database.Database, workspaceId: string): Array<string> =>
  sessionIdRows
    .all(sqlite.prepare(retireSql.workspaceSessions).all(workspaceId))
    .map((row) => row.id)

const sessionIdRows = rowReader({ id: text })

const retireSql = {
  endTurn: `update session_attention set turn_active = 0, runtime_state = 'idle',
              pending_finish = 0, settle_due_at = null, agent_calls = '[]'
            where session_id = ?`,
  workspaceSessions: "select id from sessions where workspace_id = ?"
}
