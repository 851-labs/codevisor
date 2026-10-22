import type { NavigationSnapshot } from "@codevisor/api"

import { cursorRows, idRows } from "./common-rows.js"
import { attempt } from "./errors.js"
import { jsonRecord, parseJsonRecord } from "./event-payloads.js"
import { canonicalUuid } from "./ids.js"
import { projectFromRow, sessionFromRow } from "./row-mappers.js"
import { rowReader, text } from "./row-reader.js"
import { projectLocationRows, projectRows, sessionRows, type ProjectLocationRow } from "./rows.js"
import type { ServiceContext } from "./service-context.js"
import { readSessionSkills } from "./session-skills.js"
import { sessionListSql } from "./sessions-service.js"
import { listWorkspacePanes } from "./workspace-pane-operations.js"
import { listWorkspaceRows } from "./workspaces-service.js"

const sessionStateRows = rowReader({ state_key: text, payload: text })

export const makeNavigationService = (context: ServiceContext) => ({
  listSessionsRequiringResume: attempt("listSessionsRequiringResume", () =>
    sessionIdsRequiringResume(context.sqlite)
  ),
  getSessionRuntimeState: (rawId: string) =>
    attempt("getSessionRuntimeState", () => {
      const id = canonicalUuid(rawId)
      const session = context.getSession(id)
      const rows = runtimeStateRows(context.sqlite, id)
      const state = new Map(rows.map((row) => [row.state_key, parseJsonRecord(row.payload)]))
      const metadata = state.get("runtime_metadata") ?? {}
      const modes = jsonRecord(metadata.modes)
      const currentModeId = state.get("current_mode_update")?.currentModeId
      return {
        sessionId: session.agentSessionId ?? id,
        ...metadata,
        ...(modes === undefined
          ? {}
          : {
              modes: { ...modes, ...(typeof currentModeId === "string" ? { currentModeId } : {}) }
            }),
        configOptions:
          state.get("config_option_update")?.configOptions ?? metadata.configOptions ?? []
      }
    }),
  saveSessionRuntimeState: (rawId: string, metadata: unknown) =>
    attempt("saveSessionRuntimeState", () => {
      context.sqlite
        .prepare(navigationSql.saveRuntimeMetadata)
        .run(canonicalUuid(rawId), JSON.stringify(metadata))
    }),
  getSessionSkills: (rawId: string) =>
    attempt("getSessionSkills", () => readSessionSkills(context.sqlite, canonicalUuid(rawId))),
  getNavigationSnapshot: attempt("getNavigationSnapshot", (): NavigationSnapshot => {
    const { sqlite, config, sessionSummarySelect } = context
    return sqlite.transaction(() => {
      const eventCursor = navigationEventCursor(sqlite)
      const locations = allProjectLocations(sqlite)
      const byProject = new Map<string, ProjectLocationRow[]>()
      for (const location of locations) {
        const group = byProject.get(location.project_id) ?? []
        group.push(location)
        byProject.set(location.project_id, group)
      }
      return {
        eventCursor,
        projects: projectsNewestFirst(sqlite).map((row) =>
          projectFromRow(row, byProject.get(row.id) ?? [])
        ),
        sessions: sessionsByRecency(sqlite, sessionSummarySelect).map((row) =>
          sessionFromRow(
            row,
            byProject
              .get(row.project_id)
              ?.find((location) => location.server_id === config.serverId)?.folder_path
          )
        ),
        workspaces: listWorkspaceRows(sqlite),
        panes: listWorkspacePanes(sqlite)
      }
    })()
  })
})

const sessionIdsRequiringResume = (sqlite: ServiceContext["sqlite"]): ReadonlyArray<string> =>
  idRows.all(sqlite.prepare(navigationSql.sessionsRequiringResume).all()).map((row) => row.id)

const runtimeStateRows = (sqlite: ServiceContext["sqlite"], sessionId: string) =>
  sessionStateRows.all(sqlite.prepare(navigationSql.runtimeState).all(sessionId))

const navigationEventCursor = (sqlite: ServiceContext["sqlite"]): number =>
  cursorRows.one(sqlite.prepare(navigationSql.eventCursor).get()).cursor

const allProjectLocations = (sqlite: ServiceContext["sqlite"]): ReadonlyArray<ProjectLocationRow> =>
  projectLocationRows.all(sqlite.prepare(navigationSql.projectLocations).all())

const projectsNewestFirst = (sqlite: ServiceContext["sqlite"]) =>
  projectRows.all(sqlite.prepare(navigationSql.projects).all())

const sessionsByRecency = (sqlite: ServiceContext["sqlite"], summarySelect: string) =>
  sessionRows.all(sqlite.prepare(sessionListSql(summarySelect)).all())

const navigationSql = {
  sessionsRequiringResume: `select sessions.id from sessions
      left join workspaces on workspaces.id = sessions.workspace_id collate nocase
      where coalesce(workspaces.is_archived, 0) = 0 and (
      json_extract(goal_state, '$.status') = 'active'
      or exists (select 1 from json_each(background_tasks) where json_extract(value, '$.status') in ('running', 'pending', 'in_progress'))
      or exists (select 1 from prompt_queue_items where session_id = sessions.id))`,
  runtimeState:
    "select state_key, payload from session_state where session_id = ? and state_key in ('runtime_metadata', 'config_option_update', 'current_mode_update')",
  saveRuntimeMetadata: `insert into session_state (session_id, state_key, revision, payload)
      values (?, 'runtime_metadata', 0, ?) on conflict(session_id, state_key) do update set payload = excluded.payload`,
  eventCursor:
    "select max(coalesce((select max(id) from events), 0), coalesce((select floor from sync_watermarks where subject_id = 'global'), 0)) as cursor",
  projectLocations: "select * from project_locations",
  projects: "select * from projects order by created_at desc"
}
