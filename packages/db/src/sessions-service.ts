import type { CreateSessionRequest } from "@codevisor/api"
import { isoTimestamp } from "@codevisor/api"
import { Effect } from "effect"
import { randomUUID } from "node:crypto"
import { attempt } from "./errors.js"
import { sessionConfigSelectionsFromRaw } from "./event-payloads.js"
import { canonicalUuid } from "./ids.js"
import { sessionFromRow } from "./row-mappers.js"
import type { SessionRow } from "./rows.js"
import type { CodevisorDatabaseService } from "./service.js"
import { archivedStamp, type ServiceContext } from "./service-context.js"
import { ensureSessionAttentionState, projectSessionSidebarState } from "./session-attention.js"

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
  | "getSessionConfigSelections"
  | "updateSession"
  | "replaceSessionConfigSelections"
  | "updateSessionTitleFromHarness"
  | "archiveSession"
  | "deleteSession"
> => {
  const { sqlite, config, localLocationFor, sessionSummarySelect, getSession } = context

  const createSession = Effect.fn("CodevisorDatabase.createSession")(function* (
    request: CreateSessionRequest
  ) {
    return yield* attempt("createSession", () => {
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
            title, origin, is_archived, worktree_name, workspace_id, created_at, updated_at,
            sidebar_state, sidebar_state_changed_at
          ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'idle', ?)`
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
          (request.isArchived ?? false) ? 1 : 0,
          request.worktreeName ?? null,
          request.workspaceId == null ? null : canonicalUuid(request.workspaceId),
          request.createdAt ?? now,
          request.updatedAt ?? null,
          request.updatedAt ?? request.createdAt ?? now
        )
      return getSession(id)
    })
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
              "select coalesce(max(sequence), 0) as sequence from session_attention_events where session_id = ?"
            )
            .get(id) as { readonly sequence: number }
        ).sequence
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
            .prepare(
              "update session_attention_state set pending_plan_approval = 0 where session_id = ?"
            )
            .run(id)
          projectSessionSidebarState(sqlite, id, changedAt)
        })()
        return getSession(id)
      }),
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
              title = ?,
              title_is_user_set = case
                when ? is not null and ? <> title then 1
                else title_is_user_set
              end,
              is_archived = ?,
              archived_at = ?,
              -- A direct archive/unarchive is a user act on this one chat, so
              -- it clears cascade provenance: a later project unarchive must
              -- not drag this row back with it. Updates that do NOT touch the
              -- archive bit (a rename, a worktree remap) must leave provenance
              -- alone, or restoring one chat would strand its siblings.
              archive_cascade_from = case when ? = 1 then null else archive_cascade_from end,
              agent_session_id = ?, worktree_name = ?, project_id = ?,
              harness_id = ?, harness_account_id = ?, updated_at = ?
             where id = ?`
          )
          .run(
            request.title ?? current.title,
            request.title ?? null,
            request.title ?? null,
            (request.isArchived ?? current.isArchived) ? 1 : 0,
            archivedStamp(request.isArchived, current.isArchived, current.archivedAt),
            request.isArchived === undefined ? 0 : 1,
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
    archiveSession: (rawId) =>
      attempt("archiveSession", () => {
        const id = canonicalUuid(rawId)
        sqlite.prepare("update sessions set is_archived = 1 where id = ?").run(id)
        return getSession(id)
      }),
    deleteSession: (rawId) =>
      attempt("deleteSession", () => {
        const id = canonicalUuid(rawId)
        sqlite.transaction(() => {
          const pane = sqlite
            .prepare(
              "select id, workspace_id from workspace_panes where resource_kind = 'session' and resource_id = ?"
            )
            .get(id) as { readonly id: string; readonly workspace_id: string } | undefined
          if (pane !== undefined) {
            const count = (
              sqlite
                .prepare("select count(*) as count from workspace_panes where workspace_id = ?")
                .get(pane.workspace_id) as { readonly count: number }
            ).count
            if (count > 1) {
              sqlite.prepare("delete from workspace_panes where id = ?").run(pane.id)
            } else {
              // Permanent chat deletion is another way a pane resource can
              // disappear. Apply the same final-pane invariant as Close.
              sqlite
                .prepare(
                  `update workspace_panes set
                     provider_id = 'codevisor', pane_type = 'new-tab', title = 'New tab',
                     resource_kind = null, resource_id = null, metadata = null,
                     revision = revision + 1, updated_at = ?
                   where id = ?`
                )
                .run(isoTimestamp(), pane.id)
            }
          }
          sqlite.prepare("delete from sessions where id = ?").run(id)
        })()
      })
  }
}
