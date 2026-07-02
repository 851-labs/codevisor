// Sidebar ordering helpers, ported from SidebarView.swift
// (compareWorkspaces / compareSessions / timestamp / projectTimestamp).
import type { SessionSummary, Workspace } from "@herdman/api"

export type SidebarOrganization = "byProject" | "chronological"
export type SidebarOrder = "updated" | "created"

export function sessionTimestamp(session: SessionSummary, order: SidebarOrder): string {
  if (order === "updated") return session.updatedAt ?? session.createdAt
  return session.createdAt
}

export function compareSessions(
  left: SessionSummary,
  right: SessionSummary,
  order: SidebarOrder
): number {
  const leftTimestamp = sessionTimestamp(left, order)
  const rightTimestamp = sessionTimestamp(right, order)
  if (leftTimestamp !== rightTimestamp) {
    return leftTimestamp > rightTimestamp ? -1 : 1
  }
  return left.title.localeCompare(right.title, undefined, { sensitivity: "base" })
}

export function projectTimestamp(
  workspace: Workspace,
  sessions: readonly SessionSummary[],
  order: SidebarOrder
): string {
  if (order !== "updated") return workspace.createdAt
  let latest = workspace.createdAt
  for (const session of sessions) {
    const timestamp = session.updatedAt ?? session.createdAt
    if (timestamp > latest) latest = timestamp
  }
  return latest
}

export function compareWorkspaces(
  left: Workspace,
  right: Workspace,
  sessionsByWorkspace: ReadonlyMap<string, readonly SessionSummary[]>,
  order: SidebarOrder
): number {
  const leftTimestamp = projectTimestamp(left, sessionsByWorkspace.get(left.id) ?? [], order)
  const rightTimestamp = projectTimestamp(right, sessionsByWorkspace.get(right.id) ?? [], order)
  if (leftTimestamp !== rightTimestamp) {
    return leftTimestamp > rightTimestamp ? -1 : 1
  }
  return left.name.localeCompare(right.name, undefined, { sensitivity: "base" })
}

// Applies the manual project order (newline-separated ids, like the Swift
// @AppStorage value): manually placed projects first in saved order, the rest
// by the comparator.
export function orderWorkspaces(
  workspaces: readonly Workspace[],
  manualOrder: readonly string[],
  sessionsByWorkspace: ReadonlyMap<string, readonly SessionSummary[]>,
  order: SidebarOrder
): Workspace[] {
  const indexes = new Map(manualOrder.map((id, index) => [id, index]))
  return [...workspaces].sort((left, right) => {
    const leftIndex = indexes.get(left.id)
    const rightIndex = indexes.get(right.id)
    if (leftIndex != null && rightIndex != null) return leftIndex - rightIndex
    if (leftIndex != null) return -1
    if (rightIndex != null) return 1
    return compareWorkspaces(left, right, sessionsByWorkspace, order)
  })
}
