import type {
  CreateProjectRequest,
  CreateSessionRequest,
  EventKind,
  FileMetadata,
  Project,
  ProjectLocation,
  PromptQueueItem,
  SessionSummary,
  Worktree
} from "@codevisor/api"
import { isoTimestamp } from "@codevisor/api"
import type Database from "better-sqlite3"
import { Effect } from "effect"
import { createHash, randomBytes, randomUUID } from "node:crypto"
import {
  chatAssistantSummary,
  chatRoute,
  createChatItem,
  finishAssistantChatItem,
  sessionGoalSnapshot,
  setChatRoute
} from "./chat-items.js"
import { runBlockingDataUpgrades } from "./data-upgrades.js"
import { attempt } from "./errors.js"
import {
  backgroundTasksFromRaw,
  isSessionShellEvent,
  pendingQuestionFromRaw,
  sessionConfigSelectionsFromRaw
} from "./event-payloads.js"
import { insertSessionEvent, projectChatEvent } from "./event-projection.js"
import { canonicalUuid } from "./ids.js"
import { migrations } from "./migrations.js"
import { worktreePath } from "./paths.js"
import {
  archivedWorktreeFromRow,
  conversationFromRow,
  eventFromRow,
  fileMetadataFromRow,
  fileStorageRecordFromRow,
  harnessAccountFromRow,
  harnessPendingUpdateFromRow,
  harnessUpdateStateFromRow,
  listPromptQueueSync,
  mcpServerFromRow,
  nativeMcpRemovalFromRow,
  projectFromRow,
  promptQueueFromRow,
  serializeAttachments,
  sessionEventFromRow,
  sessionFromRow,
  transcriptFromChatRow,
  updateFromRow,
  workspaceFromRow,
  worktreeFromRow
} from "./row-mappers.js"
import type {
  ArchivedWorktreeRow,
  ChatItemRow,
  ConversationRow,
  EventRow,
  FileRow,
  FileStorageState,
  HarnessAccountRecord,
  HarnessAccountRow,
  HarnessPendingUpdateRow,
  HarnessUpdateStateRow,
  McpServerRow,
  NativeConfigBackupRow,
  NativeMcpRemovalRow,
  ProjectLocationRow,
  ProjectRow,
  PromptQueueRow,
  SessionActionRow,
  SessionEventRow,
  SessionRow,
  UpdateRow,
  WorkspaceRow,
  WorktreeRow
} from "./rows.js"
import type { CodevisorDatabaseConfig, CodevisorDatabaseService } from "./service.js"
import {
  ensureSessionAttentionState,
  projectSessionAttention,
  projectSessionSidebarState
} from "./session-attention.js"

// Turn-boundary events can legitimately leave behind completed item shells
// when a harness emits no user payload or assistant output. They are useful to
// the event projector, but they are not transcript rows: returning them makes
// virtualized clients reserve estimated height for content that cannot render.
// Keep streaming shells (the live "waiting for the agent" row) and every form
// of semantic content supported by the transcript API.
const renderableChatItemPredicate = `(
  chat_items.status = 'streaming'
  or chat_items.has_details = 1
  or length(coalesce(chat_items.stop_reason, '')) > 0
  or length(coalesce(chat_items.stop_detail, '')) > 0
  or (chat_items.attachments is not null and chat_items.attachments != '[]')
  or exists (
    select 1 from chat_parts as renderable_part
    where renderable_part.item_id = chat_items.id
      and length(coalesce(renderable_part.text, '')) > 0
  )
)`

// A row count is not a render-cost bound: one assistant item can contain a
// 20k-character essay. Keep reverse pages small enough for clients to parse
// and lay out without a visible hitch, while always returning at least the
// newest row so a single oversized answer can still be reached.
const maxInitialTranscriptPageCharacters = 24_000
const maxOlderTranscriptPageCharacters = 64_000

/// Resolves the `archived_at` value for a write that may or may not be
/// changing the archived state. Re-archiving an already-archived row keeps the
/// original moment rather than refreshing it, so "archived 3 weeks ago" does
/// not reset to "just now" when an unrelated field is updated in the same
/// PATCH.
const archivedStamp = (
  requested: boolean | undefined,
  currentlyArchived: boolean,
  currentStamp: string | undefined
): string | null => {
  const next = requested ?? currentlyArchived
  if (!next) return null
  return currentStamp ?? isoTimestamp()
}

export const createService = (
  sqlite: Database.Database,
  config: CodevisorDatabaseConfig
): CodevisorDatabaseService => {
  const migrate = attempt("migrate", () => {
    sqlite.exec(
      "create table if not exists schema_migrations (id integer primary key, name text not null)"
    )
    const applied = new Set(
      sqlite
        .prepare("select id from schema_migrations")
        .all()
        .map((row) => (row as { readonly id: number }).id)
    )
    const names: Array<string> = []
    // Table rebuilds (drop + rename) would cascade-delete child rows under enforced foreign
    // keys, and `pragma foreign_keys` is a no-op inside a transaction — toggle it out here.
    sqlite.pragma("foreign_keys = OFF")
    try {
      const transaction = sqlite.transaction(() => {
        for (const migration of migrations) {
          if (applied.has(migration.id)) {
            continue
          }
          sqlite.exec(migration.sql)
          migration.run?.(sqlite, config)
          sqlite
            .prepare("insert into schema_migrations (id, name) values (?, ?)")
            .run(migration.id, migration.name)
          names.push(migration.name)
        }
        sqlite
          .prepare(
            `insert into update_state (
              id, current_version, latest_version, update_available, channel, checked_at, migration_state
            ) values (1, '0.1.0', '0.1.0', 0, 'development', null, 'idle')
            on conflict(id) do nothing`
          )
          .run()
        const violations = sqlite.pragma("foreign_key_check") as ReadonlyArray<unknown>
        if (violations.length > 0) {
          throw new Error(`Migration left foreign key violations: ${JSON.stringify(violations)}`)
        }
      })
      transaction()
      // Required data upgrades run in bounded, checkpointed transactions
      // after the schema commit. Startup remains blocking, but the old tables
      // stay untouched and an interrupted process resumes from durable rows.
      runBlockingDataUpgrades(sqlite, config)
    } finally {
      sqlite.pragma("foreign_keys = ON")
    }
    return names
  })

  const harnessAccountRows = (harnessId: string): ReadonlyArray<HarnessAccountRow> =>
    sqlite
      .prepare(
        `select a.*,
                case when s.account_id = a.id then 1 else 0 end as is_active
         from harness_accounts a
         left join harness_account_selection s on s.harness_id = a.harness_id
         where a.harness_id = ? and a.removed_at is null
         order by is_active desc, a.created_at asc`
      )
      .all(harnessId) as ReadonlyArray<HarnessAccountRow>

  const requiredHarnessAccount = (accountId: string): HarnessAccountRecord => {
    const row = sqlite
      .prepare(
        `select a.*,
                case when s.account_id = a.id then 1 else 0 end as is_active
         from harness_accounts a
         left join harness_account_selection s on s.harness_id = a.harness_id
         where a.id = ? and a.removed_at is null`
      )
      .get(accountId) as HarnessAccountRow | undefined
    if (row === undefined) throw new Error(`Harness account not found: ${accountId}`)
    return harnessAccountFromRow(row)
  }

  const appendEvent = Effect.fn("CodevisorDatabase.appendEvent")(function* (
    kind: EventKind,
    rawSubjectId: string,
    payload: unknown
  ) {
    // Subjects are usually uuid resource ids (sessions, projects); harness
    // ids and other non-uuid subjects pass through canonicalUuid untouched.
    const subjectId = canonicalUuid(rawSubjectId)
    return yield* attempt("appendEvent", () => {
      const createdAt = isoTimestamp()
      return sqlite.transaction(() => {
        const encoded = JSON.stringify(payload)
        const sessionExists =
          sqlite.prepare("select 1 from sessions where id = ?").get(subjectId) !== undefined
        const belongsInShellLog = !sessionExists || isSessionShellEvent(kind, payload)
        const globalEventId = belongsInShellLog
          ? Number(
              sqlite
                .prepare(
                  "insert into events (server_id, kind, subject_id, created_at, payload) values (?, ?, ?, ?, ?)"
                )
                .run(config.serverId, kind, subjectId, createdAt, encoded).lastInsertRowid
            )
          : undefined
        let subjectRevision: number | undefined
        if (sessionExists) {
          const sessionEvent = insertSessionEvent(sqlite, {
            session_id: subjectId,
            global_event_id: globalEventId ?? null,
            server_id: config.serverId,
            kind,
            created_at: createdAt,
            payload: encoded
          })
          subjectRevision = sessionEvent.revision
          projectChatEvent(sqlite, sessionEvent)
          projectSessionAttention(sqlite, sessionEvent)
          projectSessionSidebarState(sqlite, subjectId, createdAt)
          if (kind === "session.output") {
            sqlite
              .prepare("update sessions set updated_at = ? where id = ?")
              .run(createdAt, subjectId)
          }
        }
        return {
          id: (globalEventId ?? subjectRevision)!,
          ...(globalEventId === undefined ? {} : { globalEventId }),
          ...(subjectRevision === undefined ? {} : { subjectRevision }),
          serverId: config.serverId,
          kind,
          subjectId,
          createdAt,
          payload
        }
      })()
    })
  })

  const locationRowsFor = (projectId: string): ReadonlyArray<ProjectLocationRow> =>
    sqlite
      .prepare("select * from project_locations where project_id = ? order by created_at asc")
      .all(projectId) as ReadonlyArray<ProjectLocationRow>

  const localLocationFor = (projectId: string): ProjectLocationRow | undefined =>
    sqlite
      .prepare("select * from project_locations where project_id = ? and server_id = ?")
      .get(projectId, config.serverId) as ProjectLocationRow | undefined

  // Attention is owned by the server and read state is shared by every
  // device authenticated as this server's owner. Keep the projection in the
  // session snapshot so sidebars never need to open every transcript.
  const sessionSummarySelect = `
    select sessions.*,
      coalesce((
        select max(sequence) from session_attention_events ae
        where ae.session_id = sessions.id
      ), 0) as attention_latest_sequence,
      coalesce((
        select last_seen_sequence from session_read_state rs
        where rs.session_id = sessions.id and rs.reader_id = 'owner'
      ), 0) as attention_last_seen_sequence,
      max(
        coalesce((
          select count(*) from session_attention_events ae
          where ae.session_id = sessions.id
            and ae.sequence > coalesce((
              select last_seen_sequence from session_read_state rs
              where rs.session_id = sessions.id and rs.reader_id = 'owner'
            ), 0)
        ), 0),
        coalesce((
          select manually_unread from session_read_state rs
          where rs.session_id = sessions.id and rs.reader_id = 'owner'
        ), 0)
      ) as attention_unread_count,
      coalesce((
        select manually_unread from session_read_state rs
        where rs.session_id = sessions.id and rs.reader_id = 'owner'
      ), 0) as attention_manually_unread,
      exists(
        select 1 from session_attention_events ae
        where ae.session_id = sessions.id and ae.has_error = 1
          and ae.sequence > coalesce((
            select last_seen_sequence from session_read_state rs
            where rs.session_id = sessions.id and rs.reader_id = 'owner'
          ), 0)
      ) as attention_has_unread_error,
      coalesce((
        select pending_plan_approval from session_attention_state ast
        where ast.session_id = sessions.id
      ), 0) as pending_plan_approval
    from sessions`

  const getProject = (id: string): Project => {
    // Case-insensitive: UUID identifiers may arrive in either case. Use the
    // stored id (row.id) for the location lookup so it matches exactly.
    const row = sqlite.prepare("select * from projects where id = ? collate nocase").get(id) as
      | ProjectRow
      | undefined
    if (row === undefined) {
      throw new Error(`Project not found: ${id}`)
    }
    return projectFromRow(row, locationRowsFor(row.id))
  }

  const getSession = (rawId: string): SessionSummary => {
    // Stored session ids are canonically lowercase; tolerate uppercase ids
    // from Swift clients by normalizing the argument (see canonicalUuid).
    const id = canonicalUuid(rawId)
    const row = sqlite.prepare(`${sessionSummarySelect} where sessions.id = ?`).get(id) as
      | SessionRow
      | undefined
    if (row === undefined) {
      throw new Error(`Session not found: ${id}`)
    }
    return sessionFromRow(row, localLocationFor(row.project_id)?.folder_path)
  }

  /// Archiving a container archives the children that were still active, and
  /// stamps each with the container id that did it. Children already archived
  /// on their own are left completely untouched — including their original
  /// `archived_at` — so the later unarchive can tell the two groups apart.
  ///
  /// Callers must already hold a transaction (see updateProject).
  const cascadeArchiveProject = (projectId: string, stamp: string): void => {
    sqlite
      .prepare(
        `update workspaces set is_archived = 1, archived_at = ?, archive_cascade_from = ?
         where project_id = ? collate nocase and is_archived = 0`
      )
      .run(stamp, projectId, projectId)
    sqlite
      .prepare(
        `update sessions set is_archived = 1, archived_at = ?, archive_cascade_from = ?
         where project_id = ? collate nocase and is_archived = 0`
      )
      .run(stamp, projectId, projectId)
  }

  /// The exact inverse: revive only rows whose provenance names this project.
  /// A chat the user archived by hand before the project was archived has a
  /// null (or workspace-scoped) `archive_cascade_from` and stays archived.
  const cascadeUnarchiveProject = (projectId: string): void => {
    sqlite
      .prepare(
        `update workspaces set is_archived = 0, archived_at = null, archive_cascade_from = null
         where project_id = ? collate nocase and archive_cascade_from = ? collate nocase`
      )
      .run(projectId, projectId)
    sqlite
      .prepare(
        `update sessions set is_archived = 0, archived_at = null, archive_cascade_from = null
         where project_id = ? collate nocase and archive_cascade_from = ? collate nocase`
      )
      .run(projectId, projectId)
  }

  /// Same contract as the project cascade, one level down. Pane layout is kept
  /// (the workspace row survives) so restoring revives the surface intact.
  const cascadeArchiveWorkspace = (workspaceId: string, stamp: string): void => {
    sqlite
      .prepare(
        `update sessions set is_archived = 1, archived_at = ?, archive_cascade_from = ?
         where workspace_id = ? collate nocase and is_archived = 0`
      )
      .run(stamp, workspaceId, workspaceId)
  }

  const cascadeUnarchiveWorkspace = (workspaceId: string): void => {
    sqlite
      .prepare(
        `update sessions set is_archived = 0, archived_at = null, archive_cascade_from = null
         where workspace_id = ? collate nocase and archive_cascade_from = ? collate nocase`
      )
      .run(workspaceId, workspaceId)
  }

  const createProject = Effect.fn("CodevisorDatabase.createProject")(function* (
    request: CreateProjectRequest
  ) {
    return yield* attempt("createProject", () => {
      const now = isoTimestamp()
      // UUIDs are case-insensitive identifiers. Canonicalize to lowercase on
      // write so ids stay consistent no matter which client created them
      // (Swift uppercases, Node lowercases) — a case-only difference must not
      // spawn a duplicate project or merge one into a differently-cased row.
      const projectId = (request.id ?? randomUUID()).toLowerCase()
      const createdAt = request.createdAt ?? now

      // Idempotency: re-creating an existing project id returns it.
      const byId = sqlite
        .prepare("select id from projects where id = ? collate nocase")
        .get(projectId) as { id: string } | undefined
      if (byId !== undefined) {
        return getProject(byId.id)
      }

      // A folder maps to exactly one project per server. If this folder is
      // already claimed under a different project id (stale data, another
      // client), merge that project into the requested id instead of failing
      // on the unique(server_id, folder_path) constraint — its sessions and
      // worktrees come along.
      const claimed = sqlite
        .prepare("select project_id from project_locations where server_id = ? and folder_path = ?")
        .get(config.serverId, request.folderPath) as { project_id: string } | undefined
      if (claimed !== undefined) {
        if (request.id === undefined || claimed.project_id.toLowerCase() === projectId) {
          return getProject(claimed.project_id)
        }
        const merge = sqlite.transaction(() => {
          sqlite
            .prepare(
              `insert into projects (
                id, name, is_archived, symbol_name, origin, created_at, repo_url
              ) values (?, ?, ?, ?, ?, ?, ?)`
            )
            .run(
              projectId,
              request.name ?? basename(request.folderPath),
              (request.isArchived ?? false) ? 1 : 0,
              request.symbolName ?? "folder.fill",
              request.origin ?? "codevisor",
              createdAt,
              request.repoUrl ?? null
            )
          for (const table of ["project_locations", "sessions", "worktrees"]) {
            sqlite
              .prepare(`update ${table} set project_id = ? where project_id = ?`)
              .run(projectId, claimed.project_id)
          }
          sqlite.prepare("delete from projects where id = ?").run(claimed.project_id)
        })
        merge()
        return getProject(projectId)
      }
      const location: ProjectLocation = {
        id: randomUUID(),
        projectId,
        serverId: config.serverId,
        folderPath: request.folderPath,
        createdAt
      }
      const project: Project = {
        id: projectId,
        name: request.name ?? basename(request.folderPath),
        isArchived: request.isArchived ?? false,
        symbolName: request.symbolName ?? "folder.fill",
        origin: request.origin ?? "codevisor",
        createdAt,
        locations: [location],
        ...(request.repoUrl === undefined ? {} : { repoUrl: request.repoUrl })
      }
      const transaction = sqlite.transaction(() => {
        sqlite
          .prepare(
            `insert into projects (
              id, name, is_archived, symbol_name, origin, created_at, repo_url
            ) values (?, ?, ?, ?, ?, ?, ?)`
          )
          .run(
            project.id,
            project.name,
            project.isArchived ? 1 : 0,
            project.symbolName,
            project.origin,
            project.createdAt,
            project.repoUrl ?? null
          )
        sqlite
          .prepare(
            `insert into project_locations (
              id, project_id, server_id, folder_path, created_at
            ) values (?, ?, ?, ?, ?)`
          )
          .run(
            location.id,
            location.projectId,
            location.serverId,
            location.folderPath,
            location.createdAt
          )
      })
      transaction()
      return project
    })
  })

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
    migrate,
    close: Effect.sync(() => sqlite.close()),
    createProject,
    listProjects: attempt("listProjects", () =>
      sqlite
        .prepare("select * from projects order by created_at desc")
        .all()
        .map((row) => projectFromRow(row as ProjectRow, locationRowsFor((row as ProjectRow).id)))
    ),
    updateProject: (id, request) =>
      attempt("updateProject", () => {
        const current = getProject(id)
        // `archivedStamp` returns a moment exactly when the row ends up
        // archived, so the stamp carries the resulting state too: deriving
        // the flag and both transitions from it keeps them consistent by
        // construction rather than by three parallel conditions.
        const stamp = archivedStamp(request.isArchived, current.isArchived, current.archivedAt)
        const archiving = stamp !== null && !current.isArchived
        const unarchiving = stamp === null && current.isArchived
        // One transaction so a cascade can never half-apply: a project that
        // reads as archived while its sessions still read as active would
        // strand those chats in no sidebar section at all.
        sqlite.transaction(() => {
          sqlite
            .prepare(
              `update projects set name = ?, is_archived = ?, archived_at = ?, symbol_name = ?
               where id = ? collate nocase`
            )
            .run(
              request.name ?? current.name,
              stamp === null ? 0 : 1,
              stamp,
              request.symbolName ?? current.symbolName,
              id
            )
          if (stamp !== null && archiving) {
            cascadeArchiveProject(id, stamp)
          } else if (unarchiving) {
            cascadeUnarchiveProject(id)
          }
        })()
        return getProject(id)
      }),
    deleteProject: (id) =>
      attempt("deleteProject", () => {
        const result = sqlite.prepare("delete from projects where id = ? collate nocase").run(id)
        if (result.changes === 0) {
          throw new Error(`Project not found: ${id}`)
        }
      }),
    createWorktree: (rawProjectId, name, branch, id) =>
      attempt("createWorktree", () => {
        const projectId = canonicalUuid(rawProjectId)
        getProject(projectId)
        const worktree: Worktree = {
          id: (id ?? randomUUID()).toLowerCase(),
          projectId,
          serverId: config.serverId,
          name,
          branch,
          path: worktreePath(projectId, name),
          createdAt: isoTimestamp()
        }
        sqlite
          .prepare(
            `insert into worktrees (
              id, project_id, server_id, name, branch, created_at
            ) values (?, ?, ?, ?, ?, ?)`
          )
          .run(worktree.id, projectId, worktree.serverId, name, branch, worktree.createdAt)
        return worktree
      }),
    listWorktrees: (projectId) =>
      attempt("listWorktrees", () =>
        (
          sqlite
            .prepare("select * from worktrees where project_id = ? order by created_at asc")
            .all(canonicalUuid(projectId)) as ReadonlyArray<WorktreeRow>
        ).map(worktreeFromRow)
      ),
    deleteWorktree: (id) =>
      attempt("deleteWorktree", () => {
        sqlite.prepare("delete from worktrees where id = ?").run(canonicalUuid(id))
      }),
    createArchivedWorktree: (record) =>
      attempt("createArchivedWorktree", () => {
        const id = canonicalUuid(record.id)
        sqlite
          .prepare(
            `insert into archived_worktrees (
               id, project_id, server_id, original_name, branch, parent_sha, snapshot_ref, created_at
             ) values (?, ?, ?, ?, ?, ?, ?, ?)
             on conflict(id) do update set
               original_name = excluded.original_name,
               branch = excluded.branch,
               parent_sha = excluded.parent_sha,
               snapshot_ref = excluded.snapshot_ref`
          )
          .run(
            id,
            canonicalUuid(record.projectId),
            record.serverId,
            record.originalName,
            record.branch,
            record.parentSha,
            record.snapshotRef,
            record.createdAt
          )
        return archivedWorktreeFromRow(
          sqlite
            .prepare("select * from archived_worktrees where id = ?")
            .get(id) as ArchivedWorktreeRow
        )
      }),
    /// Restore looks up by (project, server, name) because that is all an
    /// archived session carries — `worktree_name` is the only link left once
    /// the `worktrees` row is gone.
    findArchivedWorktree: (rawProjectId, serverId, originalName) =>
      attempt("findArchivedWorktree", () => {
        const row = sqlite
          .prepare(
            `select * from archived_worktrees
             where project_id = ? collate nocase and server_id = ? and original_name = ?
             order by created_at desc limit 1`
          )
          .get(canonicalUuid(rawProjectId), serverId, originalName) as
          | ArchivedWorktreeRow
          | undefined
        return row === undefined ? undefined : archivedWorktreeFromRow(row)
      }),
    listArchivedWorktrees: (rawProjectId) =>
      attempt("listArchivedWorktrees", () =>
        (
          sqlite
            .prepare(
              "select * from archived_worktrees where project_id = ? collate nocase order by created_at desc"
            )
            .all(canonicalUuid(rawProjectId)) as ReadonlyArray<ArchivedWorktreeRow>
        ).map(archivedWorktreeFromRow)
      ),
    deleteArchivedWorktree: (id) =>
      attempt("deleteArchivedWorktree", () => {
        sqlite.prepare("delete from archived_worktrees where id = ?").run(canonicalUuid(id))
      }),
    listWorkspaces: attempt("listWorkspaces", () =>
      (
        sqlite
          .prepare("select * from workspaces order by created_at desc")
          .all() as ReadonlyArray<WorkspaceRow>
      ).map(workspaceFromRow)
    ),
    upsertWorkspace: (request) =>
      attempt("upsertWorkspace", () => {
        const projectId = canonicalUuid(request.projectId)
        getProject(projectId)
        const now = isoTimestamp()
        const id = (request.id ?? randomUUID()).toLowerCase()
        const existing = sqlite.prepare("select * from workspaces where id = ?").get(id) as
          | WorkspaceRow
          | undefined
        const stamp = archivedStamp(
          request.isArchived,
          existing?.is_archived === 1,
          existing?.archived_at ?? undefined
        )
        const wasArchived = existing?.is_archived === 1
        sqlite.transaction(() => {
          sqlite
            .prepare(
              `insert into workspaces (
                 id, server_id, project_id, name, has_custom_name, symbol_name,
                 root_directory, is_archived, archived_at, created_at, updated_at
               ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, null)
               on conflict(id) do update set
                 project_id = excluded.project_id,
                 name = excluded.name,
                 has_custom_name = excluded.has_custom_name,
                 symbol_name = excluded.symbol_name,
                 root_directory = excluded.root_directory,
                 is_archived = excluded.is_archived,
                 archived_at = excluded.archived_at,
                 updated_at = ?`
            )
            .run(
              id,
              config.serverId,
              projectId,
              request.name,
              request.hasCustomName ? 1 : 0,
              request.symbolName ?? null,
              request.rootDirectory ?? null,
              stamp === null ? 0 : 1,
              stamp,
              request.createdAt ?? now,
              now
            )
          // A full upsert can flip the archive bit just like a PATCH, so it
          // owes the same cascade — otherwise archiving via PUT would leave
          // the workspace's chats visible under a hidden workspace.
          if (stamp !== null && !wasArchived) {
            cascadeArchiveWorkspace(id, stamp)
          } else if (stamp === null && wasArchived) {
            cascadeUnarchiveWorkspace(id)
          }
        })()
        return workspaceFromRow(
          sqlite.prepare("select * from workspaces where id = ?").get(id) as WorkspaceRow
        )
      }),
    updateWorkspace: (rawId, request) =>
      attempt("updateWorkspace", () => {
        const id = canonicalUuid(rawId)
        const existing = sqlite.prepare("select * from workspaces where id = ?").get(id) as
          | WorkspaceRow
          | undefined
        if (existing === undefined) {
          throw new Error(`Workspace not found: ${id}`)
        }
        const wasArchived = existing.is_archived === 1
        // `archivedStamp` returns a moment exactly when the row ends up
        // archived, so the stamp doubles as the archived flag — deriving both
        // from it keeps them from ever disagreeing.
        const stamp = archivedStamp(
          request.isArchived,
          wasArchived,
          existing.archived_at ?? undefined
        )
        sqlite.transaction(() => {
          sqlite
            .prepare(
              `update workspaces set
                 name = ?, has_custom_name = ?, symbol_name = ?, root_directory = ?,
                 is_archived = ?, archived_at = ?, updated_at = ?
               where id = ?`
            )
            .run(
              request.name ?? existing.name,
              (request.hasCustomName ?? existing.has_custom_name === 1) ? 1 : 0,
              request.symbolName ?? existing.symbol_name,
              request.rootDirectory ?? existing.root_directory,
              stamp === null ? 0 : 1,
              stamp,
              isoTimestamp(),
              id
            )
          if (stamp !== null && !wasArchived) {
            cascadeArchiveWorkspace(id, stamp)
          } else if (stamp === null && wasArchived) {
            cascadeUnarchiveWorkspace(id)
          }
        })()
        return workspaceFromRow(
          sqlite.prepare("select * from workspaces where id = ?").get(id) as WorkspaceRow
        )
      }),
    deleteWorkspace: (id) =>
      attempt("deleteWorkspace", () => {
        const result = sqlite.prepare("delete from workspaces where id = ?").run(canonicalUuid(id))
        if (result.changes === 0) {
          throw new Error(`Workspace not found: ${id}`)
        }
      }),
    setSessionWorkspace: (sessionId, workspaceId) =>
      attempt("setSessionWorkspace", () => {
        const result = sqlite
          .prepare("update sessions set workspace_id = ? where id = ?")
          .run(workspaceId == null ? null : canonicalUuid(workspaceId), canonicalUuid(sessionId))
        if (result.changes === 0) {
          throw new Error(`Session not found: ${sessionId}`)
        }
      }),
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
        const requested =
          throughSequence === undefined || !Number.isFinite(throughSequence)
            ? latest
            : Math.max(0, Math.min(latest, Math.trunc(throughSequence)))
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
    getSessionDetail: (rawId) =>
      attempt("getSessionDetail", () => {
        const id = canonicalUuid(rawId)
        const session = getSession(id)
        const state = sqlite
          .prepare(
            "select revision as cursor, pending_question, background_tasks from sessions where id = ?"
          )
          .get(id) as {
          readonly cursor: number
          readonly pending_question: string | null
          readonly background_tasks: string
        }
        const pendingQuestion = pendingQuestionFromRaw(state.pending_question)
        const backgroundTasks = backgroundTasksFromRaw(state.background_tasks)
        const goal = sessionGoalSnapshot(sqlite, id)
        return {
          session,
          conversation: sqlite
            .prepare(
              `select chat_items.id, chat_items.role, chat_items.message_id,
                 coalesce((select text from chat_parts
                   where item_id = chat_items.id and kind = 'text' order by position limit 1), '') as text,
                 chat_items.created_at, case when chat_items.status = 'streaming' then 1 else 0 end as is_generating,
                 chat_items.attachments
               from chat_items
               where session_id = ? and ${renderableChatItemPredicate}
               order by position asc`
            )
            .all(id)
            .map((row) => conversationFromRow(row as ConversationRow)),
          promptQueue: listPromptQueueSync(sqlite, id),
          eventCursor: Number(state.cursor),
          ...(pendingQuestion === undefined ? {} : { pendingQuestion }),
          pendingPlanApproval: session.pendingPlanApproval === true,
          backgroundTasks,
          ...(goal === undefined ? {} : { goal })
        }
      }),
    getTranscriptPage: (rawSessionId, before, limit) =>
      attempt("getTranscriptPage", () => {
        const sessionId = canonicalUuid(rawSessionId)
        const session = getSession(sessionId)
        const bounded = Math.max(1, Math.min(64, Math.trunc(limit)))
        const rows = sqlite
          .prepare(
            `select chat_items.*,
               coalesce((select text from chat_parts
                 where item_id = chat_items.id and kind = 'text' order by position limit 1), '') as text,
               (select text from chat_parts
                 where item_id = chat_items.id and kind = 'plan' order by position limit 1) as plan_document
             from chat_items
             where session_id = ? and role in ('user', 'assistant')
               and ${renderableChatItemPredicate}
               and (? is null or position < ?)
             order by position desc limit ?`
          )
          .all(sessionId, before ?? null, before ?? null, bounded + 1) as ReadonlyArray<ChatItemRow>
        const candidates = rows.slice(0, bounded)
        const pageRows: ChatItemRow[] = []
        let characters = 0
        const maxCharacters =
          bounded <= 8 ? maxInitialTranscriptPageCharacters : maxOlderTranscriptPageCharacters
        for (const row of candidates) {
          const rowCharacters = row.text.length + (row.plan_document?.length ?? 0)
          if (pageRows.length > 0 && characters + rowCharacters > maxCharacters) {
            break
          }
          pageRows.push(row)
          characters += rowCharacters
        }
        const hasMore = rows.length > pageRows.length
        const items = [...pageRows].reverse().map((row) => {
          const item = transcriptFromChatRow(row)
          if (row.role !== "assistant" || row.status !== "streaming") return item
          const summary = chatAssistantSummary(sqlite, sessionId, row.id)
          return {
            ...item,
            text: summary.text,
            ...(summary.planDocument === undefined ? {} : { planDocument: summary.planDocument }),
            ...(summary.messageId === undefined ? {} : { messageId: summary.messageId })
          }
        })
        const cursor = pageRows.at(-1)?.position
        const state = sqlite
          .prepare(
            "select revision as cursor, pending_question, background_tasks from sessions where id = ?"
          )
          .get(sessionId) as {
          readonly cursor: number
          readonly pending_question: string | null
          readonly background_tasks: string
        }
        const pendingQuestion = pendingQuestionFromRaw(state.pending_question)
        const backgroundTasks = backgroundTasksFromRaw(state.background_tasks)
        const goal = sessionGoalSnapshot(sqlite, sessionId)
        return {
          items,
          ...(hasMore ? { nextBefore: String(cursor!) } : {}),
          hasMore,
          eventCursor: Number(state.cursor),
          ...(pendingQuestion === undefined ? {} : { pendingQuestion }),
          pendingPlanApproval: session.pendingPlanApproval === true,
          backgroundTasks,
          ...(goal === undefined ? {} : { goal }),
          usage: session.usage
        }
      }),
    getTranscriptItemDetails: (rawSessionId, itemId) =>
      attempt("getTranscriptItemDetails", () => {
        const sessionId = canonicalUuid(rawSessionId)
        const item = sqlite
          .prepare("select revision from chat_items where session_id = ? and id = ?")
          .get(sessionId, itemId) as { revision: number } | undefined
        if (item === undefined) return undefined
        const events = (
          sqlite
            .prepare(
              `select * from session_events
               where session_id = ? and chat_item_id = ? order by revision asc`
            )
            .all(sessionId, itemId) as ReadonlyArray<SessionEventRow>
        ).map(sessionEventFromRow)
        return { itemId, revision: item.revision, events }
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
        sqlite.prepare("delete from sessions where id = ?").run(canonicalUuid(rawId))
      }),
    appendConversationItem: (rawSessionId, role, messageId, text, isGenerating, attachments) =>
      attempt("appendConversationItem", () => {
        const sessionId = canonicalUuid(rawSessionId)
        const now = isoTimestamp()
        // Streamed messages arrive as token-sized chunks sharing a messageId.
        // Extend the newest item in place when the chunk continues it —
        // materializing one row per token grew a single answer into
        // thousands of rows, bloating the store and making session opens
        // replay-heavy. Coalescing needs a provable same-span signal, so
        // rows without a messageId (and attachment-bearing rows) still
        // insert normally.
        sqlite.transaction(() => {
          const routeKey = messageId === undefined ? undefined : `message:${role}:${messageId}`
          const routed = routeKey === undefined ? undefined : chatRoute(sqlite, sessionId, routeKey)
          const last = sqlite
            .prepare(
              "select id from chat_items where session_id = ? order by position desc limit 1"
            )
            .get(sessionId) as { id: string } | undefined
          if (
            routed !== undefined &&
            routed === last?.id &&
            (attachments === undefined || attachments.length === 0)
          ) {
            sqlite
              .prepare(
                `update chat_parts set text = coalesce(text, '') || ?, revision = revision + 1
                 where item_id = ? and kind = 'text'`
              )
              .run(text, routed)
            sqlite
              .prepare(
                "update chat_items set status = ?, updated_at = ?, revision = revision + 1 where id = ?"
              )
              .run(isGenerating ? "streaming" : "complete", now, routed)
          } else {
            const itemId = createChatItem(sqlite, sessionId, role, now, {
              text,
              ...(messageId === undefined ? {} : { messageId }),
              status: isGenerating ? "streaming" : "complete",
              ...(attachments === undefined ? {} : { attachments })
            })
            if (routeKey !== undefined && (attachments === undefined || attachments.length === 0)) {
              setChatRoute(sqlite, sessionId, routeKey, itemId)
            }
          }
          sqlite.prepare("update sessions set updated_at = ? where id = ?").run(now, sessionId)
        })()
      }),
    appendEvent,
    listEvents: (since) =>
      attempt("listEvents", () =>
        sqlite
          .prepare("select * from events where id > ? order by id asc")
          .all(since)
          .map((row) => eventFromRow(row as EventRow))
      ),
    listSubjectEvents: (rawSubjectId, since = 0) =>
      attempt("listSubjectEvents", () => {
        const subjectId = canonicalUuid(rawSubjectId)
        const isSession =
          sqlite.prepare("select 1 from sessions where id = ?").get(subjectId) !== undefined
        return isSession
          ? sqlite
              .prepare(
                `select * from session_events
                 where session_id = ? and revision > ? order by revision asc`
              )
              .all(subjectId, since)
              .map((row) => sessionEventFromRow(row as SessionEventRow))
          : sqlite
              .prepare("select * from events where subject_id = ? and id > ? order by id asc")
              .all(subjectId, since)
              .map((row) => eventFromRow(row as EventRow))
      }),
    // Queue-item ids are deliberately NOT canonicalized: a client-supplied id
    // doubles as the client's optimistic-message token and must echo back
    // byte-identical for identity reconciliation.
    createPromptQueueItem: (rawSessionId, text, attachments, id) =>
      attempt("createPromptQueueItem", () => {
        const sessionId = canonicalUuid(rawSessionId)
        getSession(sessionId)
        const now = isoTimestamp()
        const item: PromptQueueItem = {
          // A client-supplied id makes the eventual user-echo messageId the
          // client's own optimistic-message id (identity reconciliation).
          id: id ?? randomUUID(),
          sessionId,
          text,
          createdAt: now,
          updatedAt: now,
          ...(attachments === undefined || attachments.length === 0 ? {} : { attachments })
        }
        sqlite
          .prepare(
            `insert into prompt_queue_items (
              id, session_id, text, created_at, updated_at, attachments
            ) values (?, ?, ?, ?, ?, ?)`
          )
          .run(item.id, sessionId, text, now, now, serializeAttachments(attachments))
        return item
      }),
    createFile: (name, mimeType, kind, data) =>
      attempt("createFile", () => {
        const metadata: FileMetadata = {
          id: randomUUID(),
          name,
          mimeType,
          sizeBytes: data.byteLength,
          sha256: createHash("sha256").update(data).digest("hex"),
          kind,
          createdAt: isoTimestamp()
        }
        sqlite
          .prepare(
            `insert into files (
              id, name, mime_type, size_bytes, sha256, kind, created_at, data
            ) values (?, ?, ?, ?, ?, ?, ?, ?)`
          )
          .run(
            metadata.id,
            metadata.name,
            metadata.mimeType,
            metadata.sizeBytes,
            metadata.sha256,
            metadata.kind,
            metadata.createdAt,
            data
          )
        return metadata
      }),
    createDiskFile: (metadata) =>
      attempt("createDiskFile", () => {
        sqlite
          .prepare(
            `insert into files (
              id, name, mime_type, size_bytes, sha256, kind, created_at, data, storage_state
            ) values (?, ?, ?, ?, ?, ?, ?, ?, 'disk')`
          )
          .run(
            metadata.id,
            metadata.name,
            metadata.mimeType,
            metadata.sizeBytes,
            metadata.sha256,
            metadata.kind,
            metadata.createdAt,
            Buffer.alloc(0)
          )
        return metadata
      }),
    getFileMetadata: (id) =>
      attempt("getFileMetadata", () => {
        const row = sqlite
          .prepare(
            "select id, name, mime_type, size_bytes, sha256, kind, created_at from files where id = ?"
          )
          .get(id) as FileRow | undefined
        return row === undefined ? undefined : fileMetadataFromRow(row)
      }),
    getFile: (id) =>
      attempt("getFile", () => {
        const row = sqlite.prepare("select * from files where id = ?").get(id) as
          | (FileRow & { readonly data: Buffer })
          | undefined
        return row === undefined
          ? undefined
          : { metadata: fileMetadataFromRow(row), data: row.data }
      }),
    getFileStorage: (id) =>
      attempt("getFileStorage", () => {
        const row = sqlite.prepare("select * from files where id = ?").get(id) as
          | (FileRow & { readonly data: Buffer })
          | undefined
        return row === undefined ? undefined : fileStorageRecordFromRow(row)
      }),
    listFileStorage: (state, limit) =>
      attempt("listFileStorage", () =>
        (
          sqlite
            .prepare("select * from files where storage_state = ? order by rowid asc limit ?")
            .all(state, Math.max(1, limit)) as ReadonlyArray<FileRow & { readonly data: Buffer }>
        ).map(fileStorageRecordFromRow)
      ),
    fileStorageCounts: attempt("fileStorageCounts", () => {
      const counts: Record<FileStorageState, number> = { disk: 0, dual: 0, sqlite: 0 }
      const rows = sqlite
        .prepare("select storage_state, count(*) as count from files group by storage_state")
        .all() as ReadonlyArray<{
        readonly storage_state: FileStorageState
        readonly count: number
      }>
      for (const row of rows) counts[row.storage_state] = Number(row.count)
      return counts
    }),
    markFileStorageDual: (id) =>
      attempt("markFileStorageDual", () => {
        const result = sqlite
          .prepare(
            "update files set storage_state = 'dual' where id = ? and storage_state = 'sqlite'"
          )
          .run(id)
        if (result.changes === 0) {
          const current = sqlite.prepare("select storage_state from files where id = ?").get(id) as
            | { readonly storage_state: FileStorageState }
            | undefined
          if (current?.storage_state !== "dual" && current?.storage_state !== "disk") {
            throw new Error(`File not found while marking dual storage: ${id}`)
          }
        }
      }),
    markFileStorageDisk: (id) =>
      attempt("markFileStorageDisk", () => {
        const result = sqlite
          .prepare(
            "update files set storage_state = 'disk', data = x'' where id = ? and storage_state = 'dual'"
          )
          .run(id)
        if (result.changes === 0) {
          const current = sqlite.prepare("select storage_state from files where id = ?").get(id) as
            | { readonly storage_state: FileStorageState }
            | undefined
          if (current?.storage_state !== "disk") {
            throw new Error(`File is not ready for disk-only storage: ${id}`)
          }
        }
      }),
    listPromptQueue: (rawSessionId) =>
      attempt("listPromptQueue", () => {
        const sessionId = canonicalUuid(rawSessionId)
        getSession(sessionId)
        return listPromptQueueSync(sqlite, sessionId)
      }),
    updatePromptQueueItem: (rawSessionId, queueItemId, text) =>
      attempt("updatePromptQueueItem", () => {
        const sessionId = canonicalUuid(rawSessionId)
        const now = isoTimestamp()
        const result = sqlite
          .prepare(
            "update prompt_queue_items set text = ?, updated_at = ? where session_id = ? and id = ?"
          )
          .run(text, now, sessionId, queueItemId)
        if (result.changes === 0) {
          throw new Error(`Prompt queue item not found: ${queueItemId}`)
        }
        return promptQueueFromRow(
          sqlite
            .prepare("select * from prompt_queue_items where session_id = ? and id = ?")
            .get(sessionId, queueItemId) as PromptQueueRow
        )
      }),
    deletePromptQueueItem: (rawSessionId, queueItemId) =>
      attempt("deletePromptQueueItem", () => {
        const result = sqlite
          .prepare("delete from prompt_queue_items where session_id = ? and id = ?")
          .run(canonicalUuid(rawSessionId), queueItemId)
        if (result.changes === 0) {
          throw new Error(`Prompt queue item not found: ${queueItemId}`)
        }
      }),
    claimPromptQueueItem: (rawSessionId) =>
      attempt("claimPromptQueueItem", () => {
        const sessionId = canonicalUuid(rawSessionId)
        const transaction = sqlite.transaction(() => {
          const row = sqlite
            .prepare(
              `select * from prompt_queue_items
               where session_id = ? and state = 'pending'
               order by created_at asc, rowid asc
               limit 1`
            )
            .get(sessionId) as PromptQueueRow | undefined
          if (row === undefined) {
            return undefined
          }
          sqlite
            .prepare("update prompt_queue_items set state = 'processing' where id = ?")
            .run(row.id)
          return promptQueueFromRow(row)
        })
        return transaction()
      }),
    completePromptQueueItem: (rawSessionId, queueItemId) =>
      attempt("completePromptQueueItem", () => {
        sqlite
          .prepare(
            "delete from prompt_queue_items where session_id = ? and id = ? and state = 'processing'"
          )
          .run(canonicalUuid(rawSessionId), queueItemId)
      }),
    listProcessingPromptQueue: (rawSessionId) =>
      attempt("listProcessingPromptQueue", () => {
        const sessionId = canonicalUuid(rawSessionId)
        getSession(sessionId)
        return listPromptQueueSync(sqlite, sessionId, "processing")
      }),
    hasConversationMessage: (sessionId, messageId) =>
      attempt("hasConversationMessage", () =>
        Boolean(
          sqlite
            .prepare("select 1 from chat_items where session_id = ? and message_id = ? limit 1")
            .get(canonicalUuid(sessionId), messageId)
        )
      ),
    hasTerminalAssistantAfterMessage: (sessionId, messageId) =>
      attempt("hasTerminalAssistantAfterMessage", () =>
        Boolean(
          sqlite
            .prepare(
              `select 1
               from chat_items as input
               join chat_items as answer
                 on answer.session_id = input.session_id
                and answer.position > input.position
                and answer.role = 'assistant'
                and answer.status != 'streaming'
               where input.session_id = ? and input.message_id = ?
               limit 1`
            )
            .get(canonicalUuid(sessionId), messageId)
        )
      ),
    failStaleAssistantChatItems: (rawSessionId, stopDetail, excludeItemId) =>
      attempt("failStaleAssistantChatItems", () => {
        const sessionId = canonicalUuid(rawSessionId)
        getSession(sessionId)
        return sqlite.transaction(() => {
          const stale = sqlite
            .prepare(
              `select id from chat_items
               where session_id = ? and role = 'assistant' and status = 'streaming' and id != ?
               order by position asc`
            )
            .all(sessionId, excludeItemId ?? "") as Array<{ id: string }>
          const now = isoTimestamp()
          for (const row of stale) {
            finishAssistantChatItem(
              sqlite,
              sessionId,
              row.id,
              now,
              "interrupted",
              stopDetail,
              false,
              true
            )
          }
          // A failed row can never be the projection's write target again; a
          // pointer left on one would resurrect it on the next assistant event.
          sqlite
            .prepare(
              `update session_chat_state set current_item_id = null
               where session_id = ? and current_item_id in (
                 select id from chat_items where session_id = ? and status = 'failed'
               )`
            )
            .run(sessionId, sessionId)
          return stale.length
        })()
      }),
    getSessionActionResult: (sessionId, clientActionId) =>
      attempt("getSessionActionResult", () => {
        const row = sqlite
          .prepare("select * from session_actions where session_id = ? and client_action_id = ?")
          .get(canonicalUuid(sessionId), clientActionId) as SessionActionRow | undefined
        return row === undefined ? undefined : (JSON.parse(row.response) as unknown)
      }),
    saveSessionActionResult: (sessionId, clientActionId, actionKind, response) =>
      attempt("saveSessionActionResult", () => {
        sqlite
          .prepare(
            `insert into session_actions (
              session_id, client_action_id, action_kind, response, created_at
            ) values (?, ?, ?, ?, ?)
            on conflict(session_id, client_action_id) do nothing`
          )
          .run(
            canonicalUuid(sessionId),
            clientActionId,
            actionKind,
            JSON.stringify(response),
            isoTimestamp()
          )
      }),
    setHarnessEnabled: (harnessId, enabled) =>
      attempt("setHarnessEnabled", () => {
        sqlite
          .prepare(
            `insert into harness_settings (harness_id, enabled) values (?, ?)
             on conflict(harness_id) do update set enabled = excluded.enabled`
          )
          .run(harnessId, enabled ? 1 : 0)
      }),
    applyHarnessSettings: (harnesses) =>
      attempt("applyHarnessSettings", () => {
        const disabled = new Set(
          sqlite
            .prepare("select harness_id from harness_settings where enabled = 0")
            .all()
            .map((row) => (row as { readonly harness_id: string }).harness_id)
        )
        return harnesses.map((harness) => ({ ...harness, enabled: !disabled.has(harness.id) }))
      }),
    listMcpServers: attempt("listMcpServers", () =>
      (
        sqlite
          .prepare("select * from mcp_servers order by name collate nocase")
          .all() as ReadonlyArray<McpServerRow>
      ).map(mcpServerFromRow)
    ),
    getMcpServer: (id) =>
      attempt("getMcpServer", () => {
        const row = sqlite.prepare("select * from mcp_servers where id = ?").get(id) as
          | McpServerRow
          | undefined
        return row === undefined ? undefined : mcpServerFromRow(row)
      }),
    saveMcpServer: (request) =>
      attempt("saveMcpServer", () => {
        const id = request.id ?? randomUUID()
        const now = isoTimestamp()
        sqlite
          .prepare(
            `insert into mcp_servers (
               id, name, kind, transport, url, command, args, enabled, auth_type, oauth_scope,
               connection_state, tool_count, detail, secret_cipher, created_at, updated_at
             ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
             on conflict(id) do update set
               name = excluded.name, kind = excluded.kind, transport = excluded.transport, url = excluded.url,
               command = excluded.command, args = excluded.args, enabled = excluded.enabled,
               auth_type = excluded.auth_type, oauth_scope = excluded.oauth_scope,
               connection_state = excluded.connection_state, tool_count = excluded.tool_count,
               detail = excluded.detail, secret_cipher = excluded.secret_cipher,
               updated_at = excluded.updated_at`
          )
          .run(
            id,
            request.name,
            request.kind ?? "managed",
            request.transport,
            request.url ?? null,
            request.command ?? null,
            JSON.stringify(request.args ?? []),
            request.enabled ? 1 : 0,
            request.authType,
            request.oauthScope ?? null,
            request.connectionState,
            request.toolCount,
            request.detail ?? null,
            request.secretCipher ?? null,
            now,
            now
          )
        return mcpServerFromRow(
          sqlite.prepare("select * from mcp_servers where id = ?").get(id) as McpServerRow
        )
      }),
    deleteMcpServer: (id) =>
      attempt("deleteMcpServer", () => {
        sqlite.prepare("delete from mcp_servers where id = ?").run(id)
      }),
    setProjectMcpEnabled: (projectId, mcpServerId, enabled) =>
      attempt("setProjectMcpEnabled", () => {
        sqlite
          .prepare(
            `insert into project_mcp_settings (project_id, mcp_server_id, enabled) values (?, ?, ?)
             on conflict(project_id, mcp_server_id) do update set enabled = excluded.enabled`
          )
          .run(canonicalUuid(projectId), mcpServerId, enabled ? 1 : 0)
      }),
    setSessionMcpEnabled: (sessionId, mcpServerId, enabled) =>
      attempt("setSessionMcpEnabled", () => {
        sqlite
          .prepare(
            `insert into session_mcp_settings (session_id, mcp_server_id, enabled) values (?, ?, ?)
             on conflict(session_id, mcp_server_id) do update set enabled = excluded.enabled`
          )
          .run(canonicalUuid(sessionId), mcpServerId, enabled ? 1 : 0)
      }),
    resolveMcpServers: (projectId, sessionId) =>
      attempt("resolveMcpServers", () => {
        const projectSettings =
          projectId === undefined
            ? new Map<string, boolean>()
            : new Map(
                (
                  sqlite
                    .prepare(
                      "select mcp_server_id, enabled from project_mcp_settings where project_id = ?"
                    )
                    .all(canonicalUuid(projectId)) as ReadonlyArray<{
                    mcp_server_id: string
                    enabled: number
                  }>
                ).map((row) => [row.mcp_server_id, row.enabled === 1] as const)
              )
        const sessionSettings =
          sessionId === undefined
            ? new Map<string, boolean>()
            : new Map(
                (
                  sqlite
                    .prepare(
                      "select mcp_server_id, enabled from session_mcp_settings where session_id = ?"
                    )
                    .all(canonicalUuid(sessionId)) as ReadonlyArray<{
                    mcp_server_id: string
                    enabled: number
                  }>
                ).map((row) => [row.mcp_server_id, row.enabled === 1] as const)
              )
        return (
          sqlite
            .prepare("select * from mcp_servers order by name collate nocase")
            .all() as ReadonlyArray<McpServerRow>
        )
          .map(mcpServerFromRow)
          .map((server) => ({
            ...server,
            enabled:
              server.enabled &&
              projectSettings.get(server.id) !== false &&
              sessionSettings.get(server.id) !== false
          }))
      }),
    getNativeConfigBackup: (filePath) =>
      attempt("getNativeConfigBackup", () => {
        const row = sqlite
          .prepare("select * from native_config_backups where file_path = ?")
          .get(filePath) as NativeConfigBackupRow | undefined
        return row === undefined
          ? undefined
          : { backupPath: row.backup_path, createdAt: row.created_at, filePath: row.file_path }
      }),
    saveNativeConfigBackup: (record) =>
      attempt("saveNativeConfigBackup", () => {
        // First write wins: the backup captures the file before Codevisor
        // ever touched it and must never be replaced by a later state.
        sqlite
          .prepare(
            `insert into native_config_backups (file_path, backup_path, created_at)
             values (?, ?, ?) on conflict(file_path) do nothing`
          )
          .run(record.filePath, record.backupPath, record.createdAt)
      }),
    saveNativeMcpRemoval: (request) =>
      attempt("saveNativeMcpRemoval", () => {
        const id = randomUUID()
        const now = isoTimestamp()
        sqlite
          .prepare(
            `insert into native_mcp_removals
               (id, harness_id, config_path, server_name, fragment, removed_at)
             values (?, ?, ?, ?, ?, ?)`
          )
          .run(id, request.harnessId, request.configPath, request.serverName, request.fragment, now)
        return nativeMcpRemovalFromRow(
          sqlite
            .prepare("select * from native_mcp_removals where id = ?")
            .get(id) as NativeMcpRemovalRow
        )
      }),
    listNativeMcpRemovals: (includeRestored) =>
      attempt("listNativeMcpRemovals", () =>
        (
          sqlite
            .prepare(
              includeRestored === true
                ? "select * from native_mcp_removals order by removed_at desc"
                : "select * from native_mcp_removals where restored_at is null order by removed_at desc"
            )
            .all() as ReadonlyArray<NativeMcpRemovalRow>
        ).map(nativeMcpRemovalFromRow)
      ),
    markNativeMcpRemovalRestored: (id) =>
      attempt("markNativeMcpRemovalRestored", () => {
        sqlite
          .prepare("update native_mcp_removals set restored_at = ? where id = ?")
          .run(isoTimestamp(), id)
      }),
    listHarnessAccounts: (harnessId) =>
      attempt("listHarnessAccounts", () =>
        harnessAccountRows(harnessId).map(harnessAccountFromRow)
      ),
    getHarnessAccount: (accountId) =>
      attempt("getHarnessAccount", () => {
        const row = sqlite
          .prepare(
            `select a.*,
                    case when s.account_id = a.id then 1 else 0 end as is_active
             from harness_accounts a
             left join harness_account_selection s on s.harness_id = a.harness_id
             where a.id = ? and a.removed_at is null`
          )
          .get(accountId) as HarnessAccountRow | undefined
        return row === undefined ? undefined : harnessAccountFromRow(row)
      }),
    saveHarnessAccount: (request) =>
      attempt("saveHarnessAccount", () => {
        const now = isoTimestamp()
        const existing =
          request.profileKind === "default"
            ? (sqlite
                .prepare(
                  "select id from harness_accounts where harness_id = ? and profile_kind = 'default' and removed_at is null"
                )
                .get(request.harnessId) as { readonly id: string } | undefined)
            : request.profileKey === undefined
              ? undefined
              : (sqlite
                  .prepare(
                    "select id from harness_accounts where harness_id = ? and profile_key = ? and removed_at is null"
                  )
                  .get(request.harnessId, request.profileKey) as
                  | { readonly id: string }
                  | undefined)
        const id = existing?.id ?? request.id ?? randomUUID()
        sqlite
          .prepare(
            `insert into harness_accounts (
               id, harness_id, profile_kind, profile_key, label, email, organization_id,
               auth_method, auth_state, can_login, can_logout, last_checked_at, detail,
               created_at, updated_at, removed_at
             ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, null)
             on conflict(id) do update set
               label = excluded.label,
               email = excluded.email,
               organization_id = excluded.organization_id,
               auth_method = excluded.auth_method,
               auth_state = excluded.auth_state,
               can_login = excluded.can_login,
               can_logout = excluded.can_logout,
               last_checked_at = excluded.last_checked_at,
               detail = excluded.detail,
               updated_at = excluded.updated_at,
               removed_at = null`
          )
          .run(
            id,
            request.harnessId,
            request.profileKind,
            request.profileKey ?? null,
            request.label,
            request.email ?? null,
            request.organizationId ?? null,
            request.authMethod ?? null,
            request.authState,
            request.canLogin ? 1 : 0,
            request.canLogout ? 1 : 0,
            request.lastCheckedAt ?? null,
            request.detail ?? null,
            now,
            now
          )
        const selected = sqlite
          .prepare("select account_id from harness_account_selection where harness_id = ?")
          .get(request.harnessId) as { readonly account_id: string } | undefined
        if (selected === undefined) {
          sqlite
            .prepare("insert into harness_account_selection (harness_id, account_id) values (?, ?)")
            .run(request.harnessId, id)
        }
        return requiredHarnessAccount(id)
      }),
    updateHarnessAccountAuth: (accountId, request) =>
      attempt("updateHarnessAccountAuth", () => {
        const current = requiredHarnessAccount(accountId)
        sqlite
          .prepare(
            `update harness_accounts set
               label = ?, email = ?, organization_id = ?, auth_method = ?, auth_state = ?,
               can_login = ?, can_logout = ?, last_checked_at = ?, detail = ?, updated_at = ?
             where id = ? and removed_at is null`
          )
          .run(
            request.label ?? current.label,
            request.email === undefined ? (current.email ?? null) : request.email,
            request.organizationId === undefined
              ? (current.organizationId ?? null)
              : request.organizationId,
            request.authMethod === undefined ? (current.authMethod ?? null) : request.authMethod,
            request.authState,
            (request.canLogin ?? current.canLogin) ? 1 : 0,
            (request.canLogout ?? current.canLogout) ? 1 : 0,
            request.lastCheckedAt ?? isoTimestamp(),
            request.detail === undefined ? (current.detail ?? null) : request.detail,
            isoTimestamp(),
            accountId
          )
        return requiredHarnessAccount(accountId)
      }),
    setActiveHarnessAccount: (harnessId, accountId) =>
      attempt("setActiveHarnessAccount", () => {
        const account = requiredHarnessAccount(accountId)
        if (account.harnessId !== harnessId) throw new Error("Account belongs to another harness")
        sqlite
          .prepare(
            `insert into harness_account_selection (harness_id, account_id) values (?, ?)
             on conflict(harness_id) do update set account_id = excluded.account_id`
          )
          .run(harnessId, accountId)
      }),
    removeHarnessAccount: (accountId) =>
      attempt("removeHarnessAccount", () => {
        const account = requiredHarnessAccount(accountId)
        if (account.profileKind === "default") {
          throw new Error("The default harness profile cannot be removed")
        }
        const inUse = sqlite
          .prepare("select id from sessions where harness_account_id = ? limit 1")
          .get(accountId)
        if (inUse !== undefined) throw new Error("Account is used by an existing session")
        sqlite.prepare("delete from harness_account_selection where account_id = ?").run(accountId)
        sqlite
          .prepare("update harness_accounts set removed_at = ?, updated_at = ? where id = ?")
          .run(isoTimestamp(), isoTimestamp(), accountId)
      }),
    bindSessionHarnessAccount: (sessionId, accountId) =>
      attempt("bindSessionHarnessAccount", () => {
        requiredHarnessAccount(accountId)
        sqlite
          .prepare("update sessions set harness_account_id = ? where id = ?")
          .run(accountId, sessionId)
        return getSession(sessionId)
      }),
    issuePairingToken: attempt("issuePairingToken", () => {
      const token = `hm_${randomBytes(24).toString("base64url")}`
      sqlite
        .prepare("insert into auth_tokens (id, token_hash, scope, created_at) values (?, ?, ?, ?)")
        .run(randomUUID(), hashToken(token), "admin", isoTimestamp())
      return token
    }),
    verifyBearerToken: (token) =>
      attempt("verifyBearerToken", () => {
        const row = sqlite
          .prepare("select id from auth_tokens where token_hash = ?")
          .get(hashToken(token))
        return row !== undefined
      }),
    getOrCreateInstanceId: attempt("getOrCreateInstanceId", () => {
      const row = sqlite
        .prepare("select value from instance_meta where key = 'machine-id'")
        .get() as { readonly value: string } | undefined
      if (row !== undefined) return row.value
      const id = randomUUID()
      sqlite.prepare("insert into instance_meta (key, value) values ('machine-id', ?)").run(id)
      return id
    }),
    getOrCreateConnectionToken: attempt("getOrCreateConnectionToken", () => {
      const row = sqlite
        .prepare("select value from instance_meta where key = 'connection-token'")
        .get() as { readonly value: string } | undefined
      if (row !== undefined) return row.value
      // Stable across restarts and updates: the plaintext lives in
      // instance_meta so it can be shown again, and its hash goes in
      // auth_tokens so verifyBearerToken accepts it like any pairing token.
      const token = `hm_${randomBytes(24).toString("base64url")}`
      const create = sqlite.transaction(() => {
        sqlite
          .prepare("insert into instance_meta (key, value) values ('connection-token', ?)")
          .run(token)
        sqlite
          .prepare(
            "insert into auth_tokens (id, token_hash, scope, created_at) values (?, ?, ?, ?)"
          )
          .run(randomUUID(), hashToken(token), "admin", isoTimestamp())
      })
      create()
      return token
    }),
    rotateConnectionToken: attempt("rotateConnectionToken", () => {
      const existing = sqlite
        .prepare("select value from instance_meta where key = 'connection-token'")
        .get() as { readonly value: string } | undefined
      const token = `hm_${randomBytes(24).toString("base64url")}`
      const rotate = sqlite.transaction(() => {
        if (existing !== undefined) {
          // Retire the old token so previously paired clients must re-pair.
          sqlite
            .prepare("delete from auth_tokens where token_hash = ?")
            .run(hashToken(existing.value))
        }
        sqlite
          .prepare(
            `insert into instance_meta (key, value) values ('connection-token', ?)
             on conflict(key) do update set value = excluded.value`
          )
          .run(token)
        sqlite
          .prepare(
            "insert into auth_tokens (id, token_hash, scope, created_at) values (?, ?, ?, ?)"
          )
          .run(randomUUID(), hashToken(token), "admin", isoTimestamp())
      })
      rotate()
      return token
    }),
    getBrowserPreference: attempt("getBrowserPreference", () => {
      const row = sqlite
        .prepare("select value from instance_meta where key = 'browser-preference'")
        .get() as { readonly value: string } | undefined
      return row?.value === "chrome" || row?.value === "managed" ? row.value : undefined
    }),
    setBrowserPreference: (preference) =>
      attempt("setBrowserPreference", () => {
        if (preference === undefined) {
          sqlite.prepare("delete from instance_meta where key = 'browser-preference'").run()
          return
        }
        sqlite
          .prepare(
            `insert into instance_meta (key, value) values ('browser-preference', ?)
             on conflict(key) do update set value = excluded.value`
          )
          .run(preference)
      }),
    listHarnessPendingUpdates: attempt("listHarnessPendingUpdates", () =>
      (
        sqlite
          .prepare("select * from harness_pending_updates")
          .all() as Array<HarnessPendingUpdateRow>
      ).map(harnessPendingUpdateFromRow)
    ),
    setHarnessPendingUpdate: (record) =>
      attempt("setHarnessPendingUpdate", () => {
        sqlite
          .prepare(
            `insert into harness_pending_updates (
              harness_id, state, target_version, requested_at, started_at, timeout_at
            ) values (?, ?, ?, ?, ?, ?)
            on conflict(harness_id) do update set
              state = excluded.state,
              target_version = excluded.target_version,
              requested_at = excluded.requested_at,
              started_at = excluded.started_at,
              timeout_at = excluded.timeout_at`
          )
          .run(
            record.harnessId,
            record.state,
            record.targetVersion ?? null,
            record.requestedAt,
            record.startedAt ?? null,
            record.timeoutAt ?? null
          )
        return record
      }),
    clearHarnessPendingUpdate: (harnessId) =>
      attempt("clearHarnessPendingUpdate", () => {
        sqlite.prepare("delete from harness_pending_updates where harness_id = ?").run(harnessId)
      }),
    listHarnessUpdateStates: attempt("listHarnessUpdateStates", () =>
      (
        sqlite.prepare("select * from harness_update_state").all() as Array<HarnessUpdateStateRow>
      ).map(harnessUpdateStateFromRow)
    ),
    setHarnessUpdateState: (record) =>
      attempt("setHarnessUpdateState", () => {
        sqlite
          .prepare(
            `insert into harness_update_state (
              harness_id, installed_version, latest_version, update_available,
              source, install_origin, channel, checked_at
            ) values (?, ?, ?, ?, ?, ?, ?, ?)
            on conflict(harness_id) do update set
              installed_version = excluded.installed_version,
              latest_version = excluded.latest_version,
              update_available = excluded.update_available,
              source = excluded.source,
              install_origin = excluded.install_origin,
              channel = excluded.channel,
              checked_at = excluded.checked_at`
          )
          .run(
            record.harnessId,
            record.info.installedVersion ?? null,
            record.info.latestVersion ?? null,
            record.info.updateAvailable ? 1 : 0,
            record.info.source ?? null,
            record.info.installOrigin ?? null,
            record.info.channel ?? null,
            record.info.checkedAt ?? null
          )
        return record
      }),
    getUpdateInfo: attempt("getUpdateInfo", () =>
      updateFromRow(sqlite.prepare("select * from update_state where id = 1").get() as UpdateRow)
    ),
    setUpdateInfo: (update) =>
      attempt("setUpdateInfo", () => {
        sqlite
          .prepare(
            `insert into update_state (
              id, current_version, latest_version, update_available, channel, checked_at, migration_state
            ) values (1, ?, ?, ?, ?, ?, ?)
            on conflict(id) do update set
              current_version = excluded.current_version,
              latest_version = excluded.latest_version,
              update_available = excluded.update_available,
              channel = excluded.channel,
              checked_at = excluded.checked_at,
              migration_state = excluded.migration_state`
          )
          .run(
            update.currentVersion,
            update.latestVersion,
            update.updateAvailable ? 1 : 0,
            update.channel,
            update.checkedAt ?? null,
            update.migrationState
          )
        return update
      })
  }
}

const basename = (path: string): string => path.split("/").filter(Boolean).at(-1) ?? path

const hashToken = (token: string): string => createHash("sha256").update(token).digest("hex")
