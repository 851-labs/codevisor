// Sidebar ordering helpers, ported from SidebarView.swift
// (compareProjects / compareSessions / timestamp / projectTimestamp).
import type { SessionSummary, Project } from "@herdman/api"

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
  project: Project,
  sessions: readonly SessionSummary[],
  order: SidebarOrder
): string {
  if (order !== "updated") return project.createdAt
  let latest = project.createdAt
  for (const session of sessions) {
    const timestamp = session.updatedAt ?? session.createdAt
    if (timestamp > latest) latest = timestamp
  }
  return latest
}

export function compareProjects(
  left: Project,
  right: Project,
  sessionsByProject: ReadonlyMap<string, readonly SessionSummary[]>,
  order: SidebarOrder
): number {
  const leftTimestamp = projectTimestamp(left, sessionsByProject.get(left.id) ?? [], order)
  const rightTimestamp = projectTimestamp(right, sessionsByProject.get(right.id) ?? [], order)
  if (leftTimestamp !== rightTimestamp) {
    return leftTimestamp > rightTimestamp ? -1 : 1
  }
  return left.name.localeCompare(right.name, undefined, { sensitivity: "base" })
}

// Applies the manual project order (newline-separated ids, like the Swift
// @AppStorage value): manually placed projects first in saved order, the rest
// by the comparator.
export function orderProjects(
  projects: readonly Project[],
  manualOrder: readonly string[],
  sessionsByProject: ReadonlyMap<string, readonly SessionSummary[]>,
  order: SidebarOrder
): Project[] {
  const indexes = new Map(manualOrder.map((id, index) => [id, index]))
  return [...projects].sort((left, right) => {
    const leftIndex = indexes.get(left.id)
    const rightIndex = indexes.get(right.id)
    if (leftIndex != null && rightIndex != null) return leftIndex - rightIndex
    if (leftIndex != null) return -1
    if (rightIndex != null) return 1
    return compareProjects(left, right, sessionsByProject, order)
  })
}
