import type Database from "better-sqlite3"

import { canonicalUuid } from "./ids.js"
import { nextGroupPositionIn, type TabBarEntry } from "./pane-position.js"
import type { WorkspaceRow } from "./rows.js"

/// Ownership columns a workspace write resolves to.
export interface WorkspaceOwnership {
  readonly parentWorkspaceId: string | null
  readonly parentTabPosition: string
}

/// Checks that `parentId` can own `childId`: it exists, is live, and is not
/// the child or one of the child's own descendants (no ownership cycles).
const assertOwnableBy = (sqlite: Database.Database, childId: string, parentId: string): void => {
  const parent = sqlite.prepare("select is_archived from workspaces where id = ?").get(parentId) as
    | Pick<WorkspaceRow, "is_archived">
    | undefined
  if ((parent?.is_archived ?? 1) === 1) {
    throw new Error(`Parent workspace is missing or archived: ${parentId}`)
  }
  // `union` deduplicates, so the walk ends even on corrupt cyclic data.
  const cyclic = sqlite
    .prepare(
      `with recursive ancestors(id) as (
         select ?
         union
         select workspaces.parent_workspace_id from workspaces
           join ancestors on workspaces.id = ancestors.id
           where workspaces.parent_workspace_id is not null
       )
       select 1 from ancestors where id = ?`
    )
    .get(parentId, childId)
  if (cyclic !== undefined) {
    throw new Error(`Workspace ${childId} cannot be owned by its own descendant ${parentId}`)
  }
}

/// The ownership a write leaves `childId` with. `requested` is `undefined`
/// to keep the current owner, `null` to promote the workspace to the top
/// level, or the new owner's id; a new owner appends the tab group at the
/// end of its tab bar.
export const resolveOwnership = (
  sqlite: Database.Database,
  childId: string,
  existing: WorkspaceOwnership,
  requested: string | null | undefined
): WorkspaceOwnership => {
  if (requested === undefined) return existing
  if (requested === null) return { parentWorkspaceId: null, parentTabPosition: "" }
  const parentId = canonicalUuid(requested)
  if (parentId === existing.parentWorkspaceId) return existing
  assertOwnableBy(sqlite, childId, parentId)
  return {
    parentWorkspaceId: parentId,
    parentTabPosition: nextGroupPositionIn(sqlite, parentId, childId)
  }
}

/// The tab groups of the live workspaces `workspaceId` owns, for reordering
/// its tab bar.
export const ownedTabGroups = (
  sqlite: Database.Database,
  workspaceId: string
): ReadonlyArray<TabBarEntry> =>
  (
    sqlite
      .prepare(
        "select id, parent_tab_position from workspaces where parent_workspace_id = ? and is_archived = 0"
      )
      .all(workspaceId) as ReadonlyArray<Pick<WorkspaceRow, "id" | "parent_tab_position">>
  ).map((row) => ({ id: row.id, kind: "group", position: row.parent_tab_position }))
