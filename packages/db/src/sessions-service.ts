import { randomUUID } from "node:crypto"

import type { CreateSessionRequest, SessionSummary } from "@codevisor/api"
import { isoTimestamp } from "@codevisor/api"
import { Effect } from "effect"

import { attempt } from "./errors.js"
import { sessionConfigSelectionsFromRaw } from "./event-payloads.js"
import { canonicalUuid } from "./ids.js"
import { sessionFromRow } from "./row-mappers.js"
import type { SessionRow } from "./rows.js"
import type { ServiceContext } from "./service-context.js"
import type { CodevisorDatabaseService } from "./service.js"
import {
  attentionSettleDeadline,
  ensureSessionAttentionState,
  listPendingAttentionSettles,
  projectSessionSidebarState,
  settleSessionAttention
} from "./session-attention.js"

/// The synchronous insert behind `createSession`, exported so the atomic
/// workspace create can run it inside its own transaction.
export const insertSessionRow = (
  context: ServiceContext,
  request: CreateSessionRequest
): SessionSummary => {
  const { sqlite, config, getSession } = context

  const now = isoTimestamp()
  // UUIDs are case-insensitive identifiers. Canonicalize to lowercase on
  // write (mirroring createProject) so ids stay consistent no matter
  // which client created the session (Swift uppercases, Node lowercases)
  // — a case-only difference must not spawn a duplicate session row for
  // the same chat.
  const id = (request.id ?? randomUUID()).toLowerCase()
  sqlite
    .prepare(
      `insert into sessions (
            id, project_id, server_id, harness_id, harness_account_id, agent_session_id,
            title, origin, worktree_name, workspace_id, created_at, updated_at,
            sidebar_state, sidebar_state_changed_at
          ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'idle', ?)`
    )
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
      request.updatedAt ?? request.createdAt ?? now
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
  const { sqlite, config, localLocationFor, sessionSummarySelect, getSession } = context

  const createSession = Effect.fn("CodevisorDatabase.createSession")(function* (
    request: CreateSessionRequest
  ) {
    return yield* attempt("createSession", () => insertSessionRow(context, request))
  })

  return {
    createSession,
    listSessions: attempt("listSessions", () =>
      sqlite
        .prepare(
          `${sessionSummarySelect} order by coalesce(sessions.updated_at, sessions.created_at) desc`
        )
        .all()
        .map((row) =>
          sessionFromRow(
            row as SessionRow,
            localLocationFor((row as SessionRow).project_id)?.folder_path
          )
        )
    ),
    getSessionSummary: (id) => attempt("getSessionSummary", () => getSession(id)),
    markSessionRead: (rawId, throughSequence) =>
      attempt("markSessionRead", () => {
        const id = canonicalUuid(rawId)
        getSession(id)
        const latest = (
          sqlite
            .prepare(
              "select coalesce((select attention_revision from session_attention where session_id = ?), 0) as revision"
            )
            .get(id) as { readonly revision: number }
        ).revision
        const requested = Math.max(0, Math.min(latest, Math.trunc(throughSequence)))
        const changedAt = isoTimestamp()
        sqlite.transaction(() => {
          sqlite
            .prepare(
              `insert into session_read_state (
                 session_id, reader_id, last_seen_sequence, manually_unread, updated_at
               ) values (?, 'owner', ?, 0, ?)
               on conflict(session_id, reader_id) do update set
                 last_seen_sequence = max(last_seen_sequence, excluded.last_seen_sequence),
                 manually_unread = 0,
                 updated_at = excluded.updated_at`
            )
            .run(id, requested, changedAt)
          // Reading through the newest revision acknowledges an error too:
          // errored is the urgent flavor of unread, not a lock. A read that
          // was in flight when a *newer* errored turn landed keeps the flag.
          sqlite
            .prepare(
              "update session_attention set errored = 0 where session_id = ? and attention_revision <= ?"
            )
            .run(id, requested)
          projectSessionSidebarState(sqlite, id, changedAt)
        })()
        return getSession(id)
      }),
    markSessionUnread: (rawId) =>
      attempt("markSessionUnread", () => {
        const id = canonicalUuid(rawId)
        getSession(id)
        const changedAt = isoTimestamp()
        sqlite.transaction(() => {
          sqlite
            .prepare(
              `insert into session_read_state (
                 session_id, reader_id, last_seen_sequence, manually_unread, updated_at
               ) values (?, 'owner', 0, 1, ?)
               on conflict(session_id, reader_id) do update set
                 manually_unread = 1,
                 updated_at = excluded.updated_at`
            )
            .run(id, changedAt)
          projectSessionSidebarState(sqlite, id, changedAt)
        })()
        return getSession(id)
      }),
    clearSessionPlanApproval: (rawId) =>
      attempt("clearSessionPlanApproval", () => {
        const id = canonicalUuid(rawId)
        getSession(id)
        const changedAt = isoTimestamp()
        sqlite.transaction(() => {
          ensureSessionAttentionState(sqlite, id)
          sqlite
            .prepare("update session_attention set pending_plan_approval = 0 where session_id = ?")
            .run(id)
          projectSessionSidebarState(sqlite, id, changedAt)
        })()
        return getSession(id)
      }),
    settleSessionAttention: (rawId) =>
      attempt("settleSessionAttention", () => {
        const id = canonicalUuid(rawId)
        return sqlite.transaction(() =>
          settleSessionAttention(sqlite, id, isoTimestamp(), config.attentionSettleGraceMs)
        )()
      }),
    listPendingAttentionSettles: attempt("listPendingAttentionSettles", () =>
      listPendingAttentionSettles(sqlite)
    ),
    getAttentionSettleDeadline: (rawId) =>
      attempt("getAttentionSettleDeadline", () =>
        attentionSettleDeadline(sqlite, canonicalUuid(rawId))
      ),
    getSessionConfigSelections: (rawId) =>
      attempt("getSessionConfigSelections", () => {
        const id = canonicalUuid(rawId)
        const row = sqlite
          .prepare("select config_selections from sessions where id = ?")
          .get(id) as { readonly config_selections: string } | undefined
        if (row === undefined) throw new Error(`Session not found: ${id}`)
        return sessionConfigSelectionsFromRaw(row.config_selections)
      }),
    // Metadata updates deliberately leave updated_at alone: recency ordering
    // tracks conversation activity (chat events stamp it as items
    // land, the last being the finished assistant response), so opening or
    // renaming a session must not reshuffle the sidebar.
    updateSession: (rawId, request) =>
      attempt("updateSession", () => {
        const id = canonicalUuid(rawId)
        const current = getSession(id)
        sqlite
          .prepare(
            `update sessions set
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
              harness_id = ?, harness_account_id = ?, updated_at = ?
             where id = ?`
          )
          .run(
            request.titleIntent ?? null,
            request.title ?? current.title,
            request.title ?? current.title,
            request.titleIntent ?? null,
            request.titleIntent ?? null,
            request.title ?? null,
            request.title ?? null,
            request.title ?? null,
            request.agentSessionId ?? current.agentSessionId ?? null,
            // A project move re-homes the session's directory: a stale
            // worktree name from the old project must not survive it, so the
            // move applies exactly the worktree the request names (or none).
            request.projectId === undefined
              ? (request.worktreeName ?? current.worktreeName ?? null)
              : (request.worktreeName ?? null),
            request.projectId === undefined ? current.projectId : canonicalUuid(request.projectId),
            request.harnessId ?? current.harnessId,
            request.harnessAccountId ?? current.harnessAccountId ?? null,
            request.updatedAt ?? current.updatedAt ?? null,
            id
          )
        return getSession(id)
      }),
    replaceSessionConfigSelections: (rawId, selections) =>
      attempt("replaceSessionConfigSelections", () => {
        const id = canonicalUuid(rawId)
        getSession(id)
        sqlite
          .prepare("update sessions set config_selections = ? where id = ?")
          .run(JSON.stringify(selections), id)
      }),
    // This condition lives in the UPDATE itself so a user rename and a
    // harness title arriving concurrently cannot pass a stale read/check.
    updateSessionTitleFromHarness: (rawId, title) =>
      attempt("updateSessionTitleFromHarness", () => {
        const id = canonicalUuid(rawId)
        const result = sqlite
          .prepare(
            `update sessions set title = ?
             where id = ? and title_is_user_set = 0 and title <> ?`
          )
          .run(title, id, title)
        if (result.changes === 0) {
          // Preserve updateSession's missing-id behavior while returning no
          // value for protected and idempotent title updates.
          getSession(id)
          return undefined
        }
        return getSession(id)
      }),
    deleteSession: (rawId) =>
      attempt("deleteSession", () => {
        const id = canonicalUuid(rawId)
        sqlite.transaction(() => {
          // The chat's pane goes with it. An emptied workspace is a valid
          // state; clients render it locally rather than the registry
          // holding a placeholder row.
          sqlite
            .prepare(
              "delete from workspace_panes where resource_kind = 'session' and resource_id = ?"
            )
            .run(id)
          sqlite.prepare("delete from sessions where id = ?").run(id)
        })()
      })
  }
}
