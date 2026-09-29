import { nextPanePosition } from "@codevisor/api"
import type Database from "better-sqlite3"

/// The shared tab-order key for a pane newly listed in `workspaceId`: after
/// every tab the workspace already has, so a new tab opens at the end on
/// every device.
export const nextPanePositionIn = (
  sqlite: Database.Database,
  workspaceId: string,
  paneId: string
): string => {
  const last = sqlite
    .prepare(
      "select max(position) as position from workspace_panes where workspace_id = ? and position <> '' and id <> ?"
    )
    .get(workspaceId, paneId) as { readonly position: string | null } | undefined
  return nextPanePosition(last?.position ?? undefined, Date.now(), paneId)
}
