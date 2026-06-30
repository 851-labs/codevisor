import type {
  CreateSessionRequest,
  CreateWorkspaceRequest,
  EventEnvelope,
  EventKind,
  Harness,
  SessionDetail,
  SessionSummary,
  UpdateSessionRequest,
  UpdateInfo,
  UpdateWorkspaceRequest,
  Workspace
} from "@herdman/api"
import { isoTimestamp } from "@herdman/api"
import Database from "better-sqlite3"
import { createHash, randomBytes, randomUUID } from "node:crypto"
import { Context, Effect, Layer, Schema } from "effect"

export class DatabaseError extends Schema.TaggedErrorClass<DatabaseError>()("DatabaseError", {
  operation: Schema.String,
  message: Schema.String
}) {}

export interface HerdManDatabaseConfig {
  readonly filename: string
  readonly serverId: string
}

interface WorkspaceRow {
  readonly id: string
  readonly name: string
  readonly folder_path: string
  readonly is_archived: number
  readonly symbol_name: string
  readonly origin: Workspace["origin"]
  readonly created_at: string
}

interface SessionRow {
  readonly id: string
  readonly workspace_id: string
  readonly server_id: string
  readonly harness_id: string
  readonly agent_session_id: string | null
  readonly title: string
  readonly origin: SessionSummary["origin"]
  readonly is_archived: number
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

interface UpdateRow {
  readonly current_version: string
  readonly latest_version: string
  readonly update_available: number
  readonly channel: string
  readonly checked_at: string | null
  readonly migration_state: UpdateInfo["migrationState"]
}

const migrations = [
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
  }
] as const

export interface HerdManDatabaseService {
  readonly migrate: Effect.Effect<ReadonlyArray<string>, DatabaseError>
  readonly close: Effect.Effect<void>
  readonly createWorkspace: (
    request: CreateWorkspaceRequest
  ) => Effect.Effect<Workspace, DatabaseError>
  readonly listWorkspaces: Effect.Effect<ReadonlyArray<Workspace>, DatabaseError>
  readonly updateWorkspace: (
    id: string,
    request: UpdateWorkspaceRequest
  ) => Effect.Effect<Workspace, DatabaseError>
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
    text: string,
    isGenerating: boolean
  ) => Effect.Effect<void, DatabaseError>
  readonly appendEvent: (
    kind: EventKind,
    subjectId: string,
    payload: unknown
  ) => Effect.Effect<EventEnvelope, DatabaseError>
  readonly listEvents: (since: number) => Effect.Effect<ReadonlyArray<EventEnvelope>, DatabaseError>
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
    const transaction = sqlite.transaction(() => {
      for (const migration of migrations) {
        if (applied.has(migration.id)) {
          continue
        }
        sqlite.exec(migration.sql)
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
    })
    transaction()
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

  const createWorkspace = Effect.fn("HerdManDatabase.createWorkspace")(function* (
    request: CreateWorkspaceRequest
  ) {
    return yield* attempt("createWorkspace", () => {
      const now = isoTimestamp()
      const workspace: Workspace = {
        id: randomUUID(),
        name: request.name ?? basename(request.folderPath),
        folderPath: request.folderPath,
        isArchived: false,
        symbolName: "folder",
        origin: "herdman",
        createdAt: now
      }
      sqlite
        .prepare(
          `insert into workspaces (
            id, name, folder_path, is_archived, symbol_name, origin, created_at
          ) values (?, ?, ?, ?, ?, ?, ?)`
        )
        .run(
          workspace.id,
          workspace.name,
          workspace.folderPath,
          0,
          workspace.symbolName,
          workspace.origin,
          workspace.createdAt
        )
      return workspace
    })
  })

  const createSession = Effect.fn("HerdManDatabase.createSession")(function* (
    request: CreateSessionRequest
  ) {
    return yield* attempt("createSession", () => {
      const now = isoTimestamp()
      const session: SessionSummary = {
        id: randomUUID(),
        workspaceId: request.workspaceId,
        serverId: config.serverId,
        harnessId: request.harnessId,
        ...(request.agentSessionId === undefined ? {} : { agentSessionId: request.agentSessionId }),
        title: request.title ?? "New Session",
        origin: "herdman",
        isArchived: false,
        createdAt: now
      }
      sqlite
        .prepare(
          `insert into sessions (
            id, workspace_id, server_id, harness_id, agent_session_id, title, origin, is_archived, created_at
          ) values (?, ?, ?, ?, ?, ?, ?, ?, ?)`
        )
        .run(
          session.id,
          session.workspaceId,
          session.serverId,
          session.harnessId,
          request.agentSessionId ?? null,
          session.title,
          session.origin,
          0,
          session.createdAt
        )
      return session
    })
  })

  return {
    migrate,
    close: Effect.sync(() => sqlite.close()),
    createWorkspace,
    listWorkspaces: attempt("listWorkspaces", () =>
      sqlite
        .prepare("select * from workspaces order by created_at desc")
        .all()
        .map((row) => workspaceFromRow(row as WorkspaceRow))
    ),
    updateWorkspace: (id, request) =>
      attempt("updateWorkspace", () => {
        const current = getWorkspace(sqlite, id)
        const updated: Workspace = {
          ...current,
          name: request.name ?? current.name,
          isArchived: request.isArchived ?? current.isArchived,
          symbolName: request.symbolName ?? current.symbolName
        }
        sqlite
          .prepare("update workspaces set name = ?, is_archived = ?, symbol_name = ? where id = ?")
          .run(updated.name, updated.isArchived ? 1 : 0, updated.symbolName, id)
        return updated
      }),
    createSession,
    listSessions: attempt("listSessions", () =>
      sqlite
        .prepare("select * from sessions order by coalesce(updated_at, created_at) desc")
        .all()
        .map((row) => sessionFromRow(row as SessionRow))
    ),
    getSessionDetail: (id) =>
      attempt("getSessionDetail", () => ({
        session: getSession(sqlite, id),
        conversation: sqlite
          .prepare("select * from conversation_items where session_id = ? order by created_at asc")
          .all(id)
          .map((row) => conversationFromRow(row as ConversationRow))
      })),
    updateSession: (id, request) =>
      attempt("updateSession", () => {
        const current = getSession(sqlite, id)
        const now = isoTimestamp()
        sqlite
          .prepare("update sessions set title = ?, is_archived = ?, updated_at = ? where id = ?")
          .run(
            request.title ?? current.title,
            (request.isArchived ?? current.isArchived) ? 1 : 0,
            now,
            id
          )
        return getSession(sqlite, id)
      }),
    archiveSession: (id) =>
      attempt("archiveSession", () => {
        const now = isoTimestamp()
        sqlite
          .prepare("update sessions set is_archived = 1, updated_at = ? where id = ?")
          .run(now, id)
        return getSession(sqlite, id)
      }),
    deleteSession: (id) =>
      attempt("deleteSession", () => {
        sqlite.prepare("delete from sessions where id = ?").run(id)
      }),
    appendConversationItem: (sessionId, role, text, isGenerating) =>
      attempt("appendConversationItem", () => {
        const now = isoTimestamp()
        sqlite
          .prepare(
            `insert into conversation_items (
              id, session_id, role, text, created_at, is_generating
            ) values (?, ?, ?, ?, ?, ?)`
          )
          .run(randomUUID(), sessionId, role, text, now, isGenerating ? 1 : 0)
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

const workspaceFromRow = (row: WorkspaceRow): Workspace => ({
  id: row.id,
  name: row.name,
  folderPath: row.folder_path,
  isArchived: row.is_archived === 1,
  symbolName: row.symbol_name,
  origin: row.origin,
  createdAt: row.created_at
})

const sessionFromRow = (row: SessionRow): SessionSummary => ({
  id: row.id,
  workspaceId: row.workspace_id,
  serverId: row.server_id,
  harnessId: row.harness_id,
  ...(row.agent_session_id === null ? {} : { agentSessionId: row.agent_session_id }),
  title: row.title,
  origin: row.origin,
  isArchived: row.is_archived === 1,
  createdAt: row.created_at,
  ...(row.updated_at === null ? {} : { updatedAt: row.updated_at }),
  usage: {
    ...(row.usage_used === null ? {} : { used: row.usage_used }),
    ...(row.usage_size === null ? {} : { size: row.usage_size }),
    ...(row.cost_amount === null ? {} : { costAmount: row.cost_amount }),
    ...(row.cost_currency === null ? {} : { costCurrency: row.cost_currency })
  }
})

const conversationFromRow = (row: ConversationRow): SessionDetail["conversation"][number] => ({
  id: row.id,
  role: row.role,
  text: row.text,
  createdAt: row.created_at,
  isGenerating: row.is_generating === 1
})

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

const getWorkspace = (sqlite: Database.Database, id: string): Workspace => {
  const row = sqlite.prepare("select * from workspaces where id = ?").get(id) as
    | WorkspaceRow
    | undefined
  if (row === undefined) {
    throw new Error(`Workspace not found: ${id}`)
  }
  return workspaceFromRow(row)
}

const getSession = (sqlite: Database.Database, id: string): SessionSummary => {
  const row = sqlite.prepare("select * from sessions where id = ?").get(id) as
    | SessionRow
    | undefined
  if (row === undefined) {
    throw new Error(`Session not found: ${id}`)
  }
  return sessionFromRow(row)
}

const hashToken = (token: string): string => createHash("sha256").update(token).digest("hex")
