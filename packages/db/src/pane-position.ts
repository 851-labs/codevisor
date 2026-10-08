import { isoTimestamp, nextPanePosition } from "@codevisor/api"
import type Database from "better-sqlite3"

import { canonicalUuid } from "./ids.js"
import type { WorkspacePaneRow } from "./rows.js"

/// The last key in `workspaceId`'s tab bar: its panes and the tab groups of
/// the workspaces it owns share one key space. `excludedId` leaves out the
/// entry being (re)placed.
const lastTabPosition = (
  sqlite: Database.Database,
  workspaceId: string,
  excludedId: string
): string | undefined => {
  const last = sqlite
    .prepare(
      `select max(position) as position from (
         select position from workspace_panes
           where workspace_id = ? and position <> '' and id <> ?
         union all
         select parent_tab_position as position from workspaces
           where parent_workspace_id = ? and parent_tab_position <> '' and id <> ?
       )`
    )
    .get(workspaceId, excludedId, workspaceId, excludedId) as
    | { readonly position: string | null }
    | undefined
  return last?.position ?? undefined
}

/// The shared tab-order key for a pane newly listed in `workspaceId`: after
/// every tab and tab group the workspace already has, so a new tab opens at
/// the end on every device.
export const nextPanePositionIn = (
  sqlite: Database.Database,
  workspaceId: string,
  paneId: string
): string => nextPanePosition(lastTabPosition(sqlite, workspaceId, paneId), Date.now(), paneId)

/// The key for an owned workspace's tab group newly placed in its parent's
/// tab bar: at the end, like a new tab.
export const nextGroupPositionIn = (
  sqlite: Database.Database,
  parentWorkspaceId: string,
  childWorkspaceId: string
): string =>
  nextPanePosition(
    lastTabPosition(sqlite, parentWorkspaceId, childWorkspaceId),
    Date.now(),
    childWorkspaceId
  )

/// One entry of a workspace's tab bar: a pane, or the tab group of a
/// workspace it owns.
export interface TabBarEntry {
  readonly id: string
  readonly kind: "pane" | "group"
  readonly position: string
}

const orderedEntries = (
  entries: ReadonlyArray<TabBarEntry>,
  ids: ReadonlyArray<string>
): ReadonlyArray<TabBarEntry> => {
  const byId = new Map(entries.map((entry) => [entry.id, entry]))
  const listed = ids
    .map((id) => canonicalUuid(id))
    .filter((id, index, all) => byId.has(id) && all.indexOf(id) === index)
    .map((id) => byId.get(id)!)
  const unlisted = entries.filter((entry) => !listed.includes(entry))
  return [...listed, ...unlisted]
}

// Fresh ascending keys for the whole order, independent of the previous keys.
const writeTabPositions = (
  sqlite: Database.Database,
  entries: ReadonlyArray<TabBarEntry>
): void => {
  const updatePane = sqlite.prepare(
    "update workspace_panes set position = ?, updated_at = ? where id = ? and position <> ?"
  )
  const updateGroup = sqlite.prepare(
    "update workspaces set parent_tab_position = ?, updated_at = ? where id = ? and parent_tab_position <> ?"
  )
  const now = isoTimestamp()
  let previous: string | undefined
  for (const entry of entries) {
    const position = nextPanePosition(previous, Date.now(), entry.id)
    ;(entry.kind === "pane" ? updatePane : updateGroup).run(position, now, entry.id, position)
    previous = position
  }
}

/// Reorders the scoped snapshot inside the caller's synchronous transaction.
/// `ids` may name panes and owned workspaces' tab groups (`groups`); the
/// unlisted entries keep their current relative order after the listed ones.
export const reorderPanePositions = (
  sqlite: Database.Database,
  panes: ReadonlyArray<WorkspacePaneRow>,
  ids: ReadonlyArray<string>,
  groups: ReadonlyArray<TabBarEntry> = []
): void => {
  const current = [
    ...panes.map((pane) => ({ id: pane.id, kind: "pane" as const, position: pane.position })),
    ...groups
  ].toSorted((a, b) => Number(a.position > b.position) - Number(a.position < b.position))
  writeTabPositions(sqlite, orderedEntries(current, ids))
}
