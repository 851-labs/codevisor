import type { NavigationSnapshot } from "@codevisor/api"

import { attempt } from "./errors.js"
import { jsonRecord } from "./event-payloads.js"
import { canonicalUuid } from "./ids.js"
import {
  projectFromRow,
  sessionFromRow,
  workspaceFromRow,
  workspacePaneFromRow
} from "./row-mappers.js"
import type {
  ProjectRow,
  ProjectLocationRow,
  SessionRow,
  WorkspaceRow,
  WorkspacePaneRow
} from "./rows.js"
import type { ServiceContext } from "./service-context.js"

/** A single SQLite read transaction binds all navigation records to one cursor.
 * No filesystem, agent startup, Git process, or historical event replay runs here. */
export const makeNavigationService = (context: ServiceContext) => ({
  listSessionsRequiringResume: attempt("listSessionsRequiringResume", () =>
    (
      context.sqlite
        .prepare(
          `select sessions.id from sessions
      left join workspaces on workspaces.id = sessions.workspace_id collate nocase
      where coalesce(workspaces.is_archived, 0) = 0 and (
      json_extract(goal_state, '$.status') = 'active'
      or exists (select 1 from json_each(background_tasks) where json_extract(value, '$.status') in ('running', 'pending', 'in_progress'))
      or exists (select 1 from prompt_queue_items where session_id = sessions.id))`
        )
        .all() as Array<{ id: string }>
    ).map((row) => row.id)
  ),
  getSessionRuntimeState: (rawId: string) =>
    attempt("getSessionRuntimeState", () => {
      const id = canonicalUuid(rawId)
      const session = context.getSession(id)
      const rows = context.sqlite
        .prepare(
          "select state_key, payload from session_state where session_id = ? and state_key in ('runtime_metadata', 'config_option_update', 'current_mode_update')"
        )
        .all(id) as Array<{ state_key: string; payload: string }>
      const state = new Map(
        rows.map((row) => [row.state_key, JSON.parse(row.payload) as Record<string, unknown>])
      )
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
        .prepare(
          `insert into session_state (session_id, state_key, revision, payload)
      values (?, 'runtime_metadata', 0, ?) on conflict(session_id, state_key) do update set payload = excluded.payload`
        )
        .run(canonicalUuid(rawId), JSON.stringify(metadata))
    }),
  getNavigationSnapshot: attempt("getNavigationSnapshot", (): NavigationSnapshot => {
    const { sqlite, config, sessionSummarySelect } = context
    return sqlite.transaction(() => {
      const eventCursor = Number(
        (
          sqlite
            .prepare(
              "select max(coalesce((select max(id) from events), 0), coalesce((select floor from sync_watermarks where subject_id = 'global'), 0)) as cursor"
            )
            .get() as { cursor: number }
        ).cursor
      )
      const locations = sqlite
        .prepare("select * from project_locations")
        .all() as ProjectLocationRow[]
      const byProject = new Map<string, ProjectLocationRow[]>()
      for (const location of locations) {
        const group = byProject.get(location.project_id) ?? []
        group.push(location)
        byProject.set(location.project_id, group)
      }
      return {
        eventCursor,
        projects: (
          sqlite.prepare("select * from projects order by created_at desc").all() as ProjectRow[]
        ).map((row) => projectFromRow(row, byProject.get(row.id) ?? [])),
        sessions: (
          sqlite
            .prepare(
              `${sessionSummarySelect} order by coalesce(sessions.updated_at, sessions.created_at) desc`
            )
            .all() as SessionRow[]
        ).map((row) =>
          sessionFromRow(
            row,
            byProject
              .get(row.project_id)
              ?.find((location) => location.server_id === config.serverId)?.folder_path
          )
        ),
        workspaces: (
          sqlite
            .prepare("select * from workspaces order by sidebar_position, id")
            .all() as WorkspaceRow[]
        ).map(workspaceFromRow),
        panes: (
          sqlite
            .prepare("select * from workspace_panes order by created_at, id")
            .all() as WorkspacePaneRow[]
        ).map(workspacePaneFromRow)
      }
    })()
  })
})
