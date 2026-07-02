import type {
  CreateProjectRequest,
  CreateSessionRequest,
  EventEnvelope,
  EventKind,
  Harness,
  Project,
  ProjectLocation,
  PromptQueueItem,
  SessionDetail,
  SessionSummary,
  UpdateProjectRequest,
  UpdateSessionRequest,
  UpdateInfo,
  Worktree
} from "@herdman/api"
import { isoTimestamp } from "@herdman/api"
import Database from "better-sqlite3"
import { createHash, randomBytes, randomUUID } from "node:crypto"
import { Context, Effect, Layer, Schema } from "effect"
import { resolveSessionCwd, worktreePath } from "./paths.js"

export { resolveSessionCwd, worktreePath, worktreesRoot } from "./paths.js"

export class DatabaseError extends Schema.TaggedErrorClass<DatabaseError>()("DatabaseError", {
  operation: Schema.String,
  message: Schema.String
}) {}

export interface HerdManDatabaseConfig {
  readonly filename: string
  readonly serverId: string
}

interface ProjectRow {
  readonly id: string
  readonly name: string
  readonly is_archived: number
  readonly symbol_name: string
  readonly origin: Project["origin"]
  readonly created_at: string
}

interface ProjectLocationRow {
  readonly id: string
  readonly project_id: string
  readonly server_id: string
  readonly folder_path: string
  readonly created_at: string
}

interface WorktreeRow {
  readonly id: string
  readonly project_id: string
  readonly server_id: string
  readonly name: string
  readonly branch: string
  readonly created_at: string
}

interface SessionRow {
  readonly id: string
  readonly project_id: string
  readonly server_id: string
  readonly harness_id: string
  readonly agent_session_id: string | null
  readonly title: string
  readonly origin: SessionSummary["origin"]
  readonly is_archived: number
  readonly worktree_name: string | null
  readonly created_at: string
  readonly updated_at: string | null
  readonly usage_used: number | null
  readonly usage_size: number | null
  readonly cost_amount: number | null
  readonly cost_currency: string | null
}

interface ConversationRow {
  readonly id: string
  readonly role: "user" | "assistant" | "system"
  readonly message_id: string | null
  readonly text: string
  readonly created_at: string
  readonly is_generating: number
}

interface EventRow {
  readonly id: number
  readonly server_id: string
  readonly kind: EventKind
  readonly subject_id: string
  readonly created_at: string
  readonly payload: string
}

interface SessionActionRow {
  readonly session_id: string
  readonly client_action_id: string
  readonly action_kind: string
  readonly response: string
  readonly created_at: string
}

interface PromptQueueRow {
  readonly id: string
  readonly session_id: string
  readonly text: string
  readonly created_at: string
  readonly updated_at: string
}

interface UpdateRow {
  readonly current_version: string
  readonly latest_version: string
  readonly update_available: number
  readonly channel: string
  readonly checked_at: string | null
  readonly migration_state: UpdateInfo["migrationState"]
}

interface Migration {
  readonly id: number
  readonly name: string
  readonly sql: string
  /** Runs inside the migration transaction, after `sql`; use for backfills that need config values. */
  readonly run?: (sqlite: Database.Database, config: HerdManDatabaseConfig) => void
}

const migrations: ReadonlyArray<Migration> = [
  {
    id: 1,
    name: "initial",
    sql: `
      create table if not exists workspaces (
        id text primary key,
        name text not null,
        folder_path text not null unique,
        is_archived integer not null default 0,
        symbol_name text not null default 'folder',
        origin text not null,
        created_at text not null
      );

      create table if not exists sessions (
        id text primary key,
        workspace_id text not null references workspaces(id) on delete cascade,
        server_id text not null,
        harness_id text not null,
        agent_session_id text,
        title text not null,
        origin text not null,
        is_archived integer not null default 0,
        created_at text not null,
        updated_at text,
        usage_used integer,
        usage_size integer,
        cost_amount real,
        cost_currency text
      );

      create table if not exists conversation_items (
        id text primary key,
        session_id text not null references sessions(id) on delete cascade,
        role text not null,
        text text not null,
        created_at text not null,
        is_generating integer not null default 0
      );

      create table if not exists events (
        id integer primary key autoincrement,
        server_id text not null,
        kind text not null,
        subject_id text not null,
        created_at text not null,
        payload text not null
      );

      create table if not exists harness_settings (
        harness_id text primary key,
        enabled integer not null
      );

      create table if not exists auth_tokens (
        id text primary key,
        token_hash text not null unique,
        scope text not null,
        created_at text not null
      );

      create table if not exists update_state (
        id integer primary key check (id = 1),
        current_version text not null,
        latest_version text not null,
        update_available integer not null,
        channel text not null,
        checked_at text,
        migration_state text not null
      );

      create table if not exists backfill_jobs (
        id text primary key,
        name text not null,
        state text not null,
        cursor text,
        updated_at text not null
      );
    `
  },
  {
    id: 2,
    name: "session action idempotency",
    sql: `
      create table if not exists session_actions (
        session_id text not null references sessions(id) on delete cascade,
        client_action_id text not null,
        action_kind text not null,
        response text not null,
        created_at text not null,
        primary key (session_id, client_action_id)
      );
    `
  },
  {
    id: 3,
    name: "conversation message ids",
    sql: `
      alter table conversation_items add column message_id text;
      create index if not exists conversation_items_session_message_idx
        on conversation_items(session_id, message_id);
    `
  },
  {
    id: 4,
    name: "session prompt queue",
    sql: `
      create table if not exists prompt_queue_items (
        id text primary key,
        session_id text not null references sessions(id) on delete cascade,
        text text not null,
        created_at text not null,
        updated_at text not null
      );

      create index if not exists prompt_queue_items_session_created_idx
        on prompt_queue_items(session_id, created_at);
    `
  },
  {
    id: 5,
    name: "projects and worktrees",
    sql: `
      create table if not exists projects (
        id text primary key,
        name text not null,
        is_archived integer not null default 0,
        symbol_name text not null default 'folder',
        origin text not null,
        created_at text not null
      );

      insert into projects (id, name, is_archived, symbol_name, origin, created_at)
        select id, name, is_archived, symbol_name, origin, created_at from workspaces;

      create table if not exists project_locations (
        id text primary key,
        project_id text not null references projects(id) on delete cascade,
        server_id text not null,
        folder_path text not null,
        created_at text not null,
        unique (project_id, server_id),
        unique (server_id, folder_path)
      );

      create table if not exists worktrees (
        id text primary key,
        project_id text not null references projects(id) on delete cascade,
        server_id text not null,
        name text not null,
        branch text not null,
        created_at text not null,
        unique (project_id, server_id, name)
      );

      create table if not exists sessions_next (
        id text primary key,
        project_id text not null references projects(id) on delete cascade,
        server_id text not null,
        harness_id text not null,
        agent_session_id text,
        title text not null,
        origin text not null,
        is_archived integer not null default 0,
        worktree_name text,
        created_at text not null,
        updated_at text,
        usage_used integer,
        usage_size integer,
        cost_amount real,
        cost_currency text
      );

      insert into sessions_next (
        id, project_id, server_id, harness_id, agent_session_id, title, origin,
        is_archived, created_at, updated_at, usage_used, usage_size, cost_amount, cost_currency
      )
        select
          id, workspace_id, server_id, harness_id, agent_session_id, title, origin,
          is_archived, created_at, updated_at, usage_used, usage_size, cost_amount, cost_currency
        from sessions;

      drop table sessions;
      alter table sessions_next rename to sessions;
    `,
    run: (sqlite, config) => {
      sqlite
        .prepare(
          `insert into project_locations (id, project_id, server_id, folder_path, created_at)
           select id, id, ?, folder_path, created_at from workspaces`
        )
        .run(config.serverId)
      sqlite.exec("drop table workspaces")
    }
  }
]

export interface HerdManDatabaseService {
  readonly migrate: Effect.Effect<ReadonlyArray<string>, DatabaseError>
  readonly close: Effect.Effect<void>
  readonly createProject: (
    request: CreateProjectRequest
  ) => Effect.Effect<Project, DatabaseError>
  readonly listProjects: Effect.Effect<ReadonlyArray<Project>, DatabaseError>
  readonly updateProject: (
    id: string,
    request: UpdateProjectRequest
  ) => Effect.Effect<Project, DatabaseError>
  readonly deleteProject: (id: string) => Effect.Effect<void, DatabaseError>
  readonly createWorktree: (
    projectId: string,
    name: string,
    branch: string
  ) => Effect.Effect<Worktree, DatabaseError>
  readonly listWorktrees: (projectId: string) => Effect.Effect<ReadonlyArray<Worktree>, DatabaseError>
  readonly deleteWorktree: (id: string) => Effect.Effect<void, DatabaseError>
  readonly createSession: (
    request: CreateSessionRequest
  ) => Effect.Effect<SessionSummary, DatabaseError>
  readonly listSessions: Effect.Effect<ReadonlyArray<SessionSummary>, DatabaseError>
  readonly getSessionDetail: (id: string) => Effect.Effect<SessionDetail, DatabaseError>
  readonly updateSession: (
    id: string,
    request: UpdateSessionRequest
  ) => Effect.Effect<SessionSummary, DatabaseError>
  readonly archiveSession: (id: string) => Effect.Effect<SessionSummary, DatabaseError>
  readonly deleteSession: (id: string) => Effect.Effect<void, DatabaseError>
  readonly appendConversationItem: (
    sessionId: string,
    role: "user" | "assistant" | "system",
    messageId: string | undefined,
    text: string,
    isGenerating: boolean
  ) => Effect.Effect<void, DatabaseError>
  readonly appendEvent: (
    kind: EventKind,
    subjectId: string,
    payload: unknown
  ) => Effect.Effect<EventEnvelope, DatabaseError>
  readonly listEvents: (since: number) => Effect.Effect<ReadonlyArray<EventEnvelope>, DatabaseError>
  readonly createPromptQueueItem: (
    sessionId: string,
    text: string
  ) => Effect.Effect<PromptQueueItem, DatabaseError>
  readonly listPromptQueue: (
    sessionId: string
  ) => Effect.Effect<ReadonlyArray<PromptQueueItem>, DatabaseError>
  readonly updatePromptQueueItem: (
    sessionId: string,
    queueItemId: string,
    text: string
  ) => Effect.Effect<PromptQueueItem, DatabaseError>
  readonly deletePromptQueueItem: (
    sessionId: string,
    queueItemId: string
  ) => Effect.Effect<void, DatabaseError>
  readonly shiftPromptQueueItem: (
    sessionId: string
  ) => Effect.Effect<PromptQueueItem | undefined, DatabaseError>
  readonly getSessionActionResult: (
    sessionId: string,
    clientActionId: string
  ) => Effect.Effect<unknown | undefined, DatabaseError>
  readonly saveSessionActionResult: (
    sessionId: string,
    clientActionId: string,
    actionKind: string,
    response: unknown
  ) => Effect.Effect<void, DatabaseError>
  readonly setHarnessEnabled: (
    harnessId: string,
    enabled: boolean
  ) => Effect.Effect<void, DatabaseError>
  readonly applyHarnessSettings: (
    harnesses: ReadonlyArray<Harness>
  ) => Effect.Effect<ReadonlyArray<Harness>, DatabaseError>
  readonly issuePairingToken: Effect.Effect<string, DatabaseError>
  readonly verifyBearerToken: (token: string) => Effect.Effect<boolean, DatabaseError>
  readonly getUpdateInfo: Effect.Effect<UpdateInfo, DatabaseError>
  readonly setUpdateInfo: (update: UpdateInfo) => Effect.Effect<UpdateInfo, DatabaseError>
}

export class HerdManDatabase extends Context.Service<HerdManDatabase, HerdManDatabaseService>()(
  "@herdman/db/HerdManDatabase"
) {
  static readonly layer = (
    config: HerdManDatabaseConfig
  ): Layer.Layer<HerdManDatabase, DatabaseError> =>
    Layer.effect(
      HerdManDatabase,
      Effect.map(makeDatabase(config), (service) => HerdManDatabase.of(service))
    )
}

export const makeDatabase = (
  config: HerdManDatabaseConfig
): Effect.Effect<HerdManDatabaseService, DatabaseError> =>
  Effect.gen(function* () {
    const sqlite = yield* attempt("open", () => new Database(config.filename))
    sqlite.pragma("foreign_keys = ON")
    sqlite.pragma("journal_mode = WAL")
    const service = createService(sqlite, config)
    yield* service.migrate
    return service
  })

const createService = (
  sqlite: Database.Database,
  config: HerdManDatabaseConfig
): HerdManDatabaseService => {
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
    } finally {
      sqlite.pragma("foreign_keys = ON")
    }
    return names
  })

  const appendEvent = Effect.fn("HerdManDatabase.appendEvent")(function* (
    kind: EventKind,
    subjectId: string,
    payload: unknown
  ) {
    return yield* attempt("appendEvent", () => {
      const createdAt = isoTimestamp()
      const result = sqlite
        .prepare(
          "insert into events (server_id, kind, subject_id, created_at, payload) values (?, ?, ?, ?, ?)"
        )
        .run(config.serverId, kind, subjectId, createdAt, JSON.stringify(payload))
      return {
        id: Number(result.lastInsertRowid),
        serverId: config.serverId,
        kind,
        subjectId,
        createdAt,
        payload
      }
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

  const getProject = (id: string): Project => {
    const row = sqlite.prepare("select * from projects where id = ?").get(id) as
      | ProjectRow
      | undefined
    if (row === undefined) {
      throw new Error(`Project not found: ${id}`)
    }
    return projectFromRow(row, locationRowsFor(id))
  }

  const getSession = (id: string): SessionSummary => {
    const row = sqlite.prepare("select * from sessions where id = ?").get(id) as
      | SessionRow
      | undefined
    if (row === undefined) {
      throw new Error(`Session not found: ${id}`)
    }
    return sessionFromRow(row, localLocationFor(row.project_id)?.folder_path)
  }

  const createProject = Effect.fn("HerdManDatabase.createProject")(function* (
    request: CreateProjectRequest
  ) {
    return yield* attempt("createProject", () => {
      const now = isoTimestamp()
      const projectId = request.id ?? randomUUID()
      const createdAt = request.createdAt ?? now
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
        origin: request.origin ?? "herdman",
        createdAt,
        locations: [location]
      }
      const transaction = sqlite.transaction(() => {
        sqlite
          .prepare(
            `insert into projects (
              id, name, is_archived, symbol_name, origin, created_at
            ) values (?, ?, ?, ?, ?, ?)`
          )
          .run(
            project.id,
            project.name,
            project.isArchived ? 1 : 0,
            project.symbolName,
            project.origin,
            project.createdAt
          )
        sqlite
          .prepare(
            `insert into project_locations (
              id, project_id, server_id, folder_path, created_at
            ) values (?, ?, ?, ?, ?)`
          )
          .run(location.id, location.projectId, location.serverId, location.folderPath, location.createdAt)
      })
      transaction()
      return project
    })
  })

  const createSession = Effect.fn("HerdManDatabase.createSession")(function* (
    request: CreateSessionRequest
  ) {
    return yield* attempt("createSession", () => {
      const now = isoTimestamp()
      const id = request.id ?? randomUUID()
      sqlite
        .prepare(
          `insert into sessions (
            id, project_id, server_id, harness_id, agent_session_id, title, origin, is_archived, worktree_name, created_at, updated_at
          ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
        )
        .run(
          id,
          request.projectId,
          config.serverId,
          request.harnessId,
          request.agentSessionId ?? null,
          request.title ?? "New Session",
          request.origin ?? "herdman",
          (request.isArchived ?? false) ? 1 : 0,
          request.worktreeName ?? null,
          request.createdAt ?? now,
          request.updatedAt ?? null
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
        const updated: Project = {
          ...current,
          name: request.name ?? current.name,
          isArchived: request.isArchived ?? current.isArchived,
          symbolName: request.symbolName ?? current.symbolName
        }
        sqlite
          .prepare("update projects set name = ?, is_archived = ?, symbol_name = ? where id = ?")
          .run(updated.name, updated.isArchived ? 1 : 0, updated.symbolName, id)
        return updated
      }),
    deleteProject: (id) =>
      attempt("deleteProject", () => {
        const result = sqlite.prepare("delete from projects where id = ?").run(id)
        if (result.changes === 0) {
          throw new Error(`Project not found: ${id}`)
        }
      }),
    createWorktree: (projectId, name, branch) =>
      attempt("createWorktree", () => {
        getProject(projectId)
        const worktree: Worktree = {
          id: randomUUID(),
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
            .all(projectId) as ReadonlyArray<WorktreeRow>
        ).map(worktreeFromRow)
      ),
    deleteWorktree: (id) =>
      attempt("deleteWorktree", () => {
        sqlite.prepare("delete from worktrees where id = ?").run(id)
      }),
    createSession,
    listSessions: attempt("listSessions", () =>
      sqlite
        .prepare("select * from sessions order by coalesce(updated_at, created_at) desc")
        .all()
        .map((row) =>
          sessionFromRow(
            row as SessionRow,
            localLocationFor((row as SessionRow).project_id)?.folder_path
          )
        )
    ),
    getSessionDetail: (id) =>
      attempt("getSessionDetail", () => ({
        session: getSession(id),
        conversation: sqlite
          .prepare(
            "select * from conversation_items where session_id = ? order by created_at asc, rowid asc"
          )
          .all(id)
          .map((row) => conversationFromRow(row as ConversationRow)),
        promptQueue: listPromptQueueSync(sqlite, id),
        eventCursor: Number(
          (
            sqlite.prepare("select coalesce(max(id), 0) as cursor from events").get() as {
              readonly cursor: number
            }
          ).cursor
        )
      })),
    // Metadata updates deliberately leave updated_at alone: recency ordering
    // tracks conversation activity (appendConversationItem stamps it as items
    // land, the last being the finished assistant response), so opening or
    // renaming a session must not reshuffle the sidebar.
    updateSession: (id, request) =>
      attempt("updateSession", () => {
        const current = getSession(id)
        sqlite
          .prepare(
            "update sessions set title = ?, is_archived = ?, agent_session_id = ?, updated_at = ? where id = ?"
          )
          .run(
            request.title ?? current.title,
            (request.isArchived ?? current.isArchived) ? 1 : 0,
            request.agentSessionId ?? current.agentSessionId ?? null,
            request.updatedAt ?? current.updatedAt ?? null,
            id
          )
        return getSession(id)
      }),
    archiveSession: (id) =>
      attempt("archiveSession", () => {
        sqlite.prepare("update sessions set is_archived = 1 where id = ?").run(id)
        return getSession(id)
      }),
    deleteSession: (id) =>
      attempt("deleteSession", () => {
        sqlite.prepare("delete from sessions where id = ?").run(id)
      }),
    appendConversationItem: (sessionId, role, messageId, text, isGenerating) =>
      attempt("appendConversationItem", () => {
        const now = isoTimestamp()
        sqlite
          .prepare(
            `insert into conversation_items (
              id, session_id, role, message_id, text, created_at, is_generating
            ) values (?, ?, ?, ?, ?, ?, ?)`
          )
          .run(randomUUID(), sessionId, role, messageId ?? null, text, now, isGenerating ? 1 : 0)
        sqlite.prepare("update sessions set updated_at = ? where id = ?").run(now, sessionId)
      }),
    appendEvent,
    listEvents: (since) =>
      attempt("listEvents", () =>
        sqlite
          .prepare("select * from events where id > ? order by id asc")
          .all(since)
          .map((row) => eventFromRow(row as EventRow))
      ),
    createPromptQueueItem: (sessionId, text) =>
      attempt("createPromptQueueItem", () => {
        getSession(sessionId)
        const now = isoTimestamp()
        const item: PromptQueueItem = {
          id: randomUUID(),
          sessionId,
          text,
          createdAt: now,
          updatedAt: now
        }
        sqlite
          .prepare(
            `insert into prompt_queue_items (
              id, session_id, text, created_at, updated_at
            ) values (?, ?, ?, ?, ?)`
          )
          .run(item.id, sessionId, text, now, now)
        return item
      }),
    listPromptQueue: (sessionId) =>
      attempt("listPromptQueue", () => {
        getSession(sessionId)
        return listPromptQueueSync(sqlite, sessionId)
      }),
    updatePromptQueueItem: (sessionId, queueItemId, text) =>
      attempt("updatePromptQueueItem", () => {
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
    deletePromptQueueItem: (sessionId, queueItemId) =>
      attempt("deletePromptQueueItem", () => {
        const result = sqlite
          .prepare("delete from prompt_queue_items where session_id = ? and id = ?")
          .run(sessionId, queueItemId)
        if (result.changes === 0) {
          throw new Error(`Prompt queue item not found: ${queueItemId}`)
        }
      }),
    shiftPromptQueueItem: (sessionId) =>
      attempt("shiftPromptQueueItem", () => {
        const transaction = sqlite.transaction(() => {
          const row = sqlite
            .prepare(
              `select * from prompt_queue_items
               where session_id = ?
               order by created_at asc, rowid asc
               limit 1`
            )
            .get(sessionId) as PromptQueueRow | undefined
          if (row === undefined) {
            return undefined
          }
          sqlite.prepare("delete from prompt_queue_items where id = ?").run(row.id)
          return promptQueueFromRow(row)
        })
        return transaction()
      }),
    getSessionActionResult: (sessionId, clientActionId) =>
      attempt("getSessionActionResult", () => {
        const row = sqlite
          .prepare("select * from session_actions where session_id = ? and client_action_id = ?")
          .get(sessionId, clientActionId) as SessionActionRow | undefined
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
          .run(sessionId, clientActionId, actionKind, JSON.stringify(response), isoTimestamp())
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

const attempt = <A>(operation: string, run: () => A): Effect.Effect<A, DatabaseError> =>
  Effect.try({
    try: run,
    catch: (cause) =>
      new DatabaseError({
        operation,
        /* v8 ignore next -- better-sqlite3 and Node filesystem failures arrive as Error instances. */
        message: cause instanceof Error ? cause.message : String(cause)
      })
  })

const basename = (path: string): string => path.split("/").filter(Boolean).at(-1) ?? path

const projectLocationFromRow = (row: ProjectLocationRow): ProjectLocation => ({
  id: row.id,
  projectId: row.project_id,
  serverId: row.server_id,
  folderPath: row.folder_path,
  createdAt: row.created_at
})

const projectFromRow = (
  row: ProjectRow,
  locations: ReadonlyArray<ProjectLocationRow>
): Project => ({
  id: row.id,
  name: row.name,
  isArchived: row.is_archived === 1,
  symbolName: row.symbol_name,
  origin: row.origin,
  createdAt: row.created_at,
  locations: locations.map(projectLocationFromRow)
})

const worktreeFromRow = (row: WorktreeRow): Worktree => ({
  id: row.id,
  projectId: row.project_id,
  serverId: row.server_id,
  name: row.name,
  branch: row.branch,
  path: worktreePath(row.project_id, row.name),
  createdAt: row.created_at
})

const sessionFromRow = (row: SessionRow, folderPath: string | undefined): SessionSummary => {
  const cwd = resolveSessionCwd(folderPath, row.project_id, row.worktree_name ?? undefined)
  return {
    id: row.id,
    projectId: row.project_id,
    serverId: row.server_id,
    harnessId: row.harness_id,
    ...(row.agent_session_id === null ? {} : { agentSessionId: row.agent_session_id }),
    title: row.title,
    origin: row.origin,
    isArchived: row.is_archived === 1,
    ...(row.worktree_name === null ? {} : { worktreeName: row.worktree_name }),
    ...(cwd === undefined ? {} : { cwd }),
    createdAt: row.created_at,
    ...(row.updated_at === null ? {} : { updatedAt: row.updated_at }),
    usage: {
      ...(row.usage_used === null ? {} : { used: row.usage_used }),
      ...(row.usage_size === null ? {} : { size: row.usage_size }),
      ...(row.cost_amount === null ? {} : { costAmount: row.cost_amount }),
      ...(row.cost_currency === null ? {} : { costCurrency: row.cost_currency })
    }
  }
}

const conversationFromRow = (row: ConversationRow): SessionDetail["conversation"][number] => ({
  id: row.id,
  role: row.role,
  ...(row.message_id === null ? {} : { messageId: row.message_id }),
  text: row.text,
  createdAt: row.created_at,
  isGenerating: row.is_generating === 1
})

const promptQueueFromRow = (row: PromptQueueRow): PromptQueueItem => ({
  id: row.id,
  sessionId: row.session_id,
  text: row.text,
  createdAt: row.created_at,
  updatedAt: row.updated_at
})

const listPromptQueueSync = (
  sqlite: Database.Database,
  sessionId: string
): ReadonlyArray<PromptQueueItem> =>
  sqlite
    .prepare(
      `select * from prompt_queue_items
       where session_id = ?
       order by created_at asc, rowid asc`
    )
    .all(sessionId)
    .map((row) => promptQueueFromRow(row as PromptQueueRow))

const eventFromRow = (row: EventRow): EventEnvelope => ({
  id: row.id,
  serverId: row.server_id,
  kind: row.kind,
  subjectId: row.subject_id,
  createdAt: row.created_at,
  payload: JSON.parse(row.payload) as unknown
})

const updateFromRow = (row: UpdateRow): UpdateInfo => ({
  currentVersion: row.current_version,
  latestVersion: row.latest_version,
  updateAvailable: row.update_available === 1,
  channel: row.channel,
  ...(row.checked_at === null ? {} : { checkedAt: row.checked_at }),
  migrationState: row.migration_state
})

const hashToken = (token: string): string => createHash("sha256").update(token).digest("hex")
