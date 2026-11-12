import type Database from "better-sqlite3"

import { retireWorkspaceTurns } from "./session-turn-retire.js"

export interface ArchiveChange {
  readonly from: string | null
  readonly to: string | null
}

export const followWorkspaceArchive = (
  sqlite: Database.Database,
  workspaceId: string,
  change: ArchiveChange,
  changedAt: string
): void => {
  if (change.to === null) sqlite.prepare(archiveSql.restoreWith).run(workspaceId, change.from)
  else sqlite.prepare(archiveSql.archiveWith).run(change.to, workspaceId)
  retireWorkspaceTurns(sqlite, workspaceId, changedAt)
}

const archiveSql = {
  archiveWith: `update sessions set is_archived = 1, archived_at = ?
      where workspace_id = ? and is_archived = 0`,
  restoreWith: `update sessions set is_archived = 0, archived_at = null
      where workspace_id = ? and is_archived = 1 and archived_at is ?`
}
