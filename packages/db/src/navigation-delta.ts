import type { EventEnvelope, NavigationSnapshot } from "@codevisor/api"

import { jsonRecord } from "./event-payloads.js"
import {
  projectFromRow,
  sessionFromRow,
  workspaceFromRow,
  workspacePaneFromRow
} from "./row-mappers.js"
import { projectRows, sessionRows } from "./rows.js"
import { sessionByIdSql, type ServiceContext } from "./service-context.js"
import type { SyncBatch } from "./sync-journal.js"
import { paneRow } from "./workspace-pane-operations.js"
import { readWorkspaceRow } from "./workspaces-service.js"

export const materializeNavigationDelta = (
  context: ServiceContext,
  batch: SyncBatch
): SyncBatch => {
  const changes = batch.events.filter((event) => event.kind === "navigation.changed")
  const last = changes.at(-1)
  if (last === undefined) return batch
  const { sqlite, locationRowsFor, sessionSummarySelect, localLocationFor } = context
  const ids = new Map<string, Set<string>>()
  for (const change of changes) {
    const payload = jsonRecord(change.payload)
    const source = payload?.table
    const table = changedTable(source)
    const id = source === "project_locations" ? payload?.projectId : change.subjectId
    if (typeof table !== "string" || typeof id !== "string")
      return { events: [], cursor: batch.cursor, requiresSnapshot: true }
    const group = ids.get(table) ?? new Set<string>()
    group.add(id)
    ids.set(table, group)
  }
  const projects: NavigationSnapshot["projects"][number][] = []
  const sessions: NavigationSnapshot["sessions"][number][] = []
  const workspaces: NavigationSnapshot["workspaces"][number][] = []
  const panes: NavigationSnapshot["panes"][number][] = []
  const deleted: Array<{ table: string; id: string }> = []
  for (const id of ids.get("projects") ?? []) {
    const row = projectRow(sqlite, id)
    if (row === undefined) deleted.push({ table: "projects", id })
    else projects.push(projectFromRow(row, locationRowsFor(id)))
  }
  for (const id of ids.get("sessions") ?? []) {
    const row = sessionSummaryRow(sqlite, sessionSummarySelect, id)
    if (row === undefined) deleted.push({ table: "sessions", id })
    else sessions.push(sessionFromRow(row, localLocationFor(row.project_id)?.folder_path))
  }
  for (const id of ids.get("workspaces") ?? []) {
    const row = readWorkspaceRow(sqlite, id)
    if (row === undefined) deleted.push({ table: "workspaces", id })
    else workspaces.push(workspaceFromRow(row))
  }
  for (const id of ids.get("workspace_panes") ?? []) {
    const row = paneRow(sqlite, id)
    if (row === undefined) deleted.push({ table: "workspace_panes", id })
    else panes.push(workspacePaneFromRow(row))
  }
  const delta: EventEnvelope = {
    ...last,
    payload: { eventCursor: last.id, projects, sessions, workspaces, panes, deleted }
  }
  const events = [
    ...batch.events.filter((event) => event.kind !== "navigation.changed"),
    delta
  ].toSorted((a, b) => a.id - b.id)
  if (Buffer.byteLength(JSON.stringify(events)) > 512 * 1024)
    return { events: [], cursor: batch.cursor, requiresSnapshot: true }
  return { ...batch, events }
}

const changedTable = (source: unknown): unknown => {
  if (source === "project_locations") return "projects"
  if (source === "session_attention" || source === "session_read_state") return "sessions"
  return source
}

const projectRow = (sqlite: ServiceContext["sqlite"], id: string) =>
  projectRows.maybe(sqlite.prepare(projectByIdSql).get(id))

const sessionSummaryRow = (sqlite: ServiceContext["sqlite"], summarySelect: string, id: string) =>
  sessionRows.maybe(sqlite.prepare(sessionByIdSql(summarySelect)).get(id))

const projectByIdSql = "select * from projects where id = ?"
