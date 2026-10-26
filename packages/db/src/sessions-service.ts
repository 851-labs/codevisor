import { randomUUID } from "node:crypto"

import type { CreateSessionRequest, SessionSummary, UpdateSessionRequest } from "@codevisor/api"
import { isoTimestamp } from "@codevisor/api"
import { Effect } from "effect"

import { pendingQuestionRows } from "./common-rows.js"
import { attempt } from "./errors.js"
import { pendingQuestionFromRaw, sessionConfigSelectionsFromRaw } from "./event-payloads.js"
import { canonicalUuid } from "./ids.js"
import { serializeLabels, sessionFromRow } from "./row-mappers.js"
import { rowReader, text } from "./row-reader.js"
import { sessionRows } from "./rows.js"
import type { ServiceContext } from "./service-context.js"
import type { CodevisorDatabaseService } from "./service.js"
import { makeSessionAttentionService } from "./session-attention-service.js"
import { deleteSessionWithFiles } from "./session-files.js"

export const insertSessionRow = (
  context: ServiceContext,
  request: CreateSessionRequest
): SessionSummary => {
  const { sqlite, config, getSession } = context

  const now = isoTimestamp()
  const id = (request.id ?? randomUUID()).toLowerCase()
  sqlite
    .prepare(sessionSql.insert)
    .run(
      id,
      canonicalUuid(request.projectId),
      config.serverId,
      request.harnessId,
      request.harnessAccountId ?? null,
      request.agentSessionId ?? null,
      request.title ?? "New Session",
      request.origin ?? "codevisor",
      request.worktreeName ?? null,
      request.workspaceId == null ? null : canonicalUuid(request.workspaceId),
      request.createdAt ?? now,
      request.updatedAt ?? null,
      request.updatedAt ?? request.createdAt ?? now,
      request.parentSessionId == null ? null : canonicalUuid(request.parentSessionId),
      serializeLabels(request.labels),
      JSON.stringify(request.configSelections ?? {})
    )
  return getSession(id)
}

export const makeSessionsService = (
  context: ServiceContext
): Pick<
  CodevisorDatabaseService,
  | "createSession"
  | "listSessions"
  | "getSessionSummary"
  | "getSessionPendingQuestion"
  | "markSessionRead"
  | "markSessionUnread"
  | "clearSessionPlanApproval"
  | "settleSessionAttention"
  | "listPendingAttentionSettles"
  | "getAttentionSettleDeadline"
  | "getSessionConfigSelections"
  | "updateSession"
  | "replaceSessionConfigSelections"
  | "updateSessionTitleFromHarness"
  | "deleteSession"
> => {
  const { sqlite, getSession } = context

  const createSession = Effect.fn("CodevisorDatabase.createSession")(function* (
    request: CreateSessionRequest
  ) {
    return yield* attempt("createSession", () => insertSessionRow(context, request))
  })

  return {
    createSession,
    listSessions: attempt("listSessions", () => sessionsByRecency(context)),
    getSessionSummary: (id) => attempt("getSessionSummary", () => getSession(id)),
    getSessionPendingQuestion: (rawId) =>
      attempt("getSessionPendingQuestion", () =>
        pendingQuestionFromRaw(pendingQuestionJson(sqlite, rawId))
      ),
    ...makeSessionAttentionService(sqlite, getSession),
    getSessionConfigSelections: (rawId) =>
      attempt("getSessionConfigSelections", () => {
        const id = canonicalUuid(rawId)
        const selections = configSelectionsJson(sqlite, id)
        if (selections === undefined) throw new Error(`Session not found: ${id}`)
        return sessionConfigSelectionsFromRaw(selections)
      }),
    updateSession: (rawId, request) =>
      attempt("updateSession", () => {
        const id = canonicalUuid(rawId)
        const current = getSession(id)
        sqlite.prepare(sessionSql.update).run(...sessionUpdateParams(id, request, current))
        return getSession(id)
      }),
    replaceSessionConfigSelections: (rawId, selections, unavailable) =>
      attempt("replaceSessionConfigSelections", () => {
        const id = canonicalUuid(rawId)
        getSession(id)
        if (unavailable === undefined) {
          sqlite.prepare(configSelectionSql.replace).run(JSON.stringify(selections), id)
          return
        }
        sqlite
          .prepare(configSelectionSql.replaceWithUnavailable)
          .run(JSON.stringify(selections), JSON.stringify(unavailable), id)
      }),
    updateSessionTitleFromHarness: (rawId, title) =>
      attempt("updateSessionTitleFromHarness", () => {
        const id = canonicalUuid(rawId)
        const result = sqlite.prepare(sessionSql.setHarnessTitle).run(title, id, title)
        if (result.changes === 0) {
          getSession(id)
          return undefined
        }
        return getSession(id)
      }),
    deleteSession: (rawId) =>
      attempt("deleteSession", () => {
        const id = canonicalUuid(rawId)
        sqlite.transaction(() => {
          sqlite.prepare(sessionSql.deletePanes).run(id)
          deleteSessionWithFiles(sqlite, id, () => sqlite.prepare(sessionSql.delete).run(id))
        })()
      })
  }
}

const sessionsByRecency = (context: ServiceContext): ReadonlyArray<SessionSummary> => {
  const { sqlite, localLocationFor, sessionSummarySelect } = context

  return sqlite
    .prepare(sessionListSql(sessionSummarySelect))
    .all()
    .map((raw) => {
      const row = sessionRows.one(raw)
      return sessionFromRow(row, localLocationFor(row.project_id)?.folder_path)
    })
}

const sessionUpdateParams = (
  id: string,
  request: UpdateSessionRequest,
  current: SessionSummary
): ReadonlyArray<string | number | null> => [
  request.titleIntent ?? null,
  request.title ?? current.title,
  request.title ?? current.title,
  request.titleIntent ?? null,
  request.titleIntent ?? null,
  request.title ?? null,
  request.title ?? null,
  request.title ?? null,
  request.agentSessionId ?? current.agentSessionId ?? null,
  request.projectId === undefined
    ? (request.worktreeName ?? current.worktreeName ?? null)
    : (request.worktreeName ?? null),
  request.projectId === undefined ? current.projectId : canonicalUuid(request.projectId),
  request.harnessId ?? current.harnessId,
  request.harnessAccountId ?? current.harnessAccountId ?? null,
  request.updatedAt ?? current.updatedAt ?? null,
  request.labels === undefined ? 0 : 1,
  serializeLabels(request.labels),
  id
]

const pendingQuestionJson = (sqlite: ServiceContext["sqlite"], rawId: string): string | null =>
  pendingQuestionRows.maybe(sqlite.prepare(sessionSql.pendingQuestion).get(canonicalUuid(rawId)))
    ?.pending_question ?? null

const configSelectionsJson = (sqlite: ServiceContext["sqlite"], id: string): string | undefined =>
  configSelectionRows.maybe(sqlite.prepare(configSelectionSql.byId).get(id))?.config_selections

const configSelectionRows = rowReader({ config_selections: text })

export const sessionListSql = (summarySelect: string): string =>
  `${summarySelect} order by coalesce(sessions.updated_at, sessions.created_at) desc`

const sessionSql = {
  insert: `insert into sessions (
            id, project_id, server_id, harness_id, harness_account_id, agent_session_id,
            title, origin, worktree_name, workspace_id, created_at, updated_at,
            sidebar_state, sidebar_state_changed_at, parent_session_id, labels,
            config_selections
          ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'idle', ?, ?, ?, ?)`,
  pendingQuestion: "select pending_question from sessions where id = ?",
  update: `update sessions set
              title = case
                when ? = 'fallback' then case
                  when title_is_user_set = 0 and title in ('New Chat', 'New Session') then ?
                  else title
                end
                else ?
              end,
              title_is_user_set = case
                when ? = 'fallback' then title_is_user_set
                when ? = 'rename' and ? is not null then 1
                when ? is not null and ? <> title then 1
                else title_is_user_set
              end,
              agent_session_id = ?, worktree_name = ?, project_id = ?,
              harness_id = ?, harness_account_id = ?, updated_at = ?,
              labels = case when ? then ? else labels end
             where id = ?`,
  setHarnessTitle: `update sessions set title = ?
             where id = ? and title_is_user_set = 0 and title <> ?`,
  deletePanes: "delete from workspace_panes where resource_kind = 'session' and resource_id = ?",
  delete: "delete from sessions where id = ?"
}

const configSelectionSql = {
  byId: "select config_selections from sessions where id = ?",
  replace: "update sessions set config_selections = ? where id = ?",
  replaceWithUnavailable:
    "update sessions set config_selections = ?, unavailable_config_selections = ? where id = ?"
}
