import { isoTimestamp, nextPanePosition } from "@codevisor/api"
import type Database from "better-sqlite3"

import { canonicalUuid } from "./ids.js"
import type { WorkspacePaneRow } from "./rows.js"

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

const orderedPaneIds = (
  panes: ReadonlyArray<WorkspacePaneRow>,
  paneIds: ReadonlyArray<string>
): ReadonlyArray<string> => {
  const known = new Set(panes.map((pane) => pane.id))
  const listed = paneIds
    .map((id) => canonicalUuid(id))
    .filter((id, index, all) => known.has(id) && all.indexOf(id) === index)
  const unlisted = panes.filter((pane) => !listed.includes(pane.id)).map((pane) => pane.id)
  return [...listed, ...unlisted]
}

const writePanePositions = (sqlite: Database.Database, paneIds: ReadonlyArray<string>): void => {
  const update = sqlite.prepare(
    "update workspace_panes set position = ?, updated_at = ? where id = ? and position <> ?"
  )
  const now = isoTimestamp()
  let previous: string | undefined
  for (const id of paneIds) {
    const position = nextPanePosition(previous, Date.now(), id)
    update.run(position, now, id, position)
    previous = position
  }
}

export const reorderPanePositions = (
  sqlite: Database.Database,
  panes: ReadonlyArray<WorkspacePaneRow>,
  paneIds: ReadonlyArray<string>
): void => {
  const ordered = orderedPaneIds(panes, paneIds)
  writePanePositions(sqlite, ordered)
}
