import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import {
  NavigationDelta,
  type EventEnvelope,
  type Project,
  type SessionSummary
} from "@codevisor/api"
import Database from "better-sqlite3"
import { Effect, Schema } from "effect"
import { afterEach, onTestFinished } from "vitest"

import { createService } from "./create-service.js"
import type { DatabaseError } from "./errors.js"
import { canonicalUuid } from "./ids.js"
import { eventFromRow, sessionEventFromRow } from "./row-mappers.js"
import { eventRows, sessionEventRows } from "./rows.js"
import type { CodevisorDatabaseConfig, CodevisorDatabaseService } from "./service.js"

const tempDirs: Array<string> = []

export const tempDatabase = (): string => {
  const dir = mkdtempSync(join(tmpdir(), "codevisor-db-"))
  tempDirs.push(dir)
  return join(dir, "codevisor.sqlite")
}

export const run = <A>(effect: Effect.Effect<A, DatabaseError>): Promise<A> =>
  Effect.runPromise(effect)

afterEach(() => {
  for (const dir of tempDirs.splice(0)) {
    rmSync(dir, { force: true, recursive: true })
  }
})

const readDatabase = <A>(filename: string, read: (sqlite: Database.Database) => A): A => {
  const sqlite = new Database(filename, { readonly: true })
  try {
    return read(sqlite)
  } finally {
    sqlite.close()
  }
}

export const navigationDelta = (event: EventEnvelope | undefined): NavigationDelta =>
  Schema.decodeUnknownSync(NavigationDelta)(event?.payload)

export const listEvents = (filename: string, since = 0): ReadonlyArray<EventEnvelope> =>
  readDatabase(filename, (sqlite) =>
    sqlite
      .prepare(eventLogSql.after)
      .all(since)
      .map((row) => eventFromRow(eventRows.one(row)))
  )

export const listSubjectEvents = (
  filename: string,
  rawSubjectId: string,
  since = 0
): ReadonlyArray<EventEnvelope> =>
  readDatabase(filename, (sqlite) => {
    const subjectId = canonicalUuid(rawSubjectId)
    if (isSessionSubject(sqlite, subjectId)) return sessionEventsAfter(sqlite, subjectId, since)
    return subjectEventsAfter(sqlite, subjectId, since)
  })

export const buildV4Fixture = (filename: string): void => {
  const sqlite = new Database(filename)
  try {
    sqlite.exec(v4FixtureSql)
  } finally {
    sqlite.close()
  }
}

export const memoryDatabase = async (): Promise<{
  sqlite: Database.Database
  config: CodevisorDatabaseConfig
  db: CodevisorDatabaseService
  project: Project
  session: SessionSummary
}> => {
  const sqlite = new Database(":memory:")
  const config = { filename: ":memory:", serverId: "local" }
  const db = createService(sqlite, config)
  onTestFinished(() => run(db.close))
  await run(db.migrate)
  const project = await run(db.createProject({ folderPath: "/tmp/transcript-state-test" }))
  const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
  return { sqlite, config, db, project, session }
}

const isSessionSubject = (sqlite: Database.Database, subjectId: string): boolean =>
  sqlite.prepare(eventLogSql.session).get(subjectId) !== undefined

const sessionEventsAfter = (
  sqlite: Database.Database,
  sessionId: string,
  since: number
): ReadonlyArray<EventEnvelope> =>
  sqlite
    .prepare(eventLogSql.sessionAfter)
    .all(sessionId, since)
    .map((row) => sessionEventFromRow(sessionEventRows.one(row)))

const subjectEventsAfter = (
  sqlite: Database.Database,
  subjectId: string,
  since: number
): ReadonlyArray<EventEnvelope> =>
  sqlite
    .prepare(eventLogSql.subjectAfter)
    .all(subjectId, since)
    .map((row) => eventFromRow(eventRows.one(row)))

const eventLogSql = {
  after: "select * from events where id > ? order by id asc",
  session: "select 1 from sessions where id = ?",
  sessionAfter:
    "select * from session_events where session_id = ? and revision > ? order by revision asc",
  subjectAfter: "select * from events where subject_id = ? and id > ? order by id asc"
}

const v4FixtureSql = `
    create table schema_migrations (id integer primary key, name text not null);
    insert into schema_migrations (id, name) values
      (1, 'initial'), (2, 'session action idempotency'),
      (3, 'conversation message ids'), (4, 'session prompt queue');

    create table workspaces (
      id text primary key,
      name text not null,
      folder_path text not null unique,
      is_archived integer not null default 0,
      symbol_name text not null default 'folder',
      origin text not null,
      created_at text not null
    );

    create table sessions (
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

    create table conversation_items (
      id text primary key,
      session_id text not null references sessions(id) on delete cascade,
      role text not null,
      text text not null,
      created_at text not null,
      is_generating integer not null default 0,
      message_id text
    );

    create table events (
      id integer primary key autoincrement,
      server_id text not null,
      kind text not null,
      subject_id text not null,
      created_at text not null,
      payload text not null
    );

    create table harness_settings (harness_id text primary key, enabled integer not null);

    create table auth_tokens (
      id text primary key,
      token_hash text not null unique,
      scope text not null,
      created_at text not null
    );

    create table update_state (
      id integer primary key check (id = 1),
      current_version text not null,
      latest_version text not null,
      update_available integer not null,
      channel text not null,
      checked_at text,
      migration_state text not null
    );

    create table backfill_jobs (
      id text primary key,
      name text not null,
      state text not null,
      cursor text,
      updated_at text not null
    );

    create table sync_entries (
      namespace text not null,
      key text not null,
      value text not null,
      deleted integer not null default 0,
      ts_wall integer not null,
      ts_counter integer not null,
      ts_device text not null,
      primary key (namespace, key)
    );

    create table session_actions (
      session_id text not null references sessions(id) on delete cascade,
      client_action_id text not null,
      action_kind text not null,
      response text not null,
      created_at text not null,
      primary key (session_id, client_action_id)
    );

    create table prompt_queue_items (
      id text primary key,
      session_id text not null references sessions(id) on delete cascade,
      text text not null,
      created_at text not null,
      updated_at text not null
    );

    insert into workspaces (id, name, folder_path, is_archived, symbol_name, origin, created_at)
      values ('ws-1', 'Codevisor', '/tmp/codevisor', 0, 'folder', 'herdman', '2026-06-01T00:00:00.000Z');
    insert into sessions (id, workspace_id, server_id, harness_id, agent_session_id, title, origin, is_archived, created_at)
      values ('sess-1', 'ws-1', 'local', 'codex', 'agent-1', 'Old Session', 'herdman', 0, '2026-06-01T01:00:00.000Z');
    insert into events (server_id, kind, subject_id, created_at, payload)
      values ('local', 'session.created', 'sess-1', '2026-06-01T01:00:00.000Z',
        '{"id":"sess-1","origin":"herdman"}');
    -- A scratchpad event from before the notes feature was removed. Migration
    -- 33 must purge it: the kind has left the API vocabulary, so replaying it
    -- to clients would fan out something nothing understands.
    insert into events (server_id, kind, subject_id, created_at, payload)
      values ('local', 'workspace.notes.updated', 'ws-1', '2026-06-01T01:00:30.000Z',
        '{"workspaceId":"ws-1","content":"{}"}');
    insert into conversation_items (id, session_id, role, text, created_at, is_generating, message_id)
      values ('conv-1', 'sess-1', 'user', 'hello', '2026-06-01T01:01:00.000Z', 0, 'user-1');
    insert into prompt_queue_items (id, session_id, text, created_at, updated_at)
      values ('queue-1', 'sess-1', 'queued', '2026-06-01T01:02:00.000Z', '2026-06-01T01:02:00.000Z');
    insert into session_actions (session_id, client_action_id, action_kind, response, created_at)
      values ('sess-1', 'action-1', 'prompt', '{}', '2026-06-01T01:03:00.000Z');
  `

export const rewindBotModesSql = `
  alter table bots drop column mode;
  delete from schema_migrations where id = 87;
`

export const rewindWorkspaceNamesSql = `
  drop index workspaces_main_session_id;
  drop trigger workspace_name_main_session;
  drop trigger workspace_name_main_session_title;
  delete from schema_migrations where id = 86;
`

export const rewindMainSessionSql = `
  ${rewindWorkspaceNamesSql}
  drop trigger workspace_main_session_insert;
  drop trigger workspace_main_session_move;
  drop trigger workspace_main_session_delete;
  alter table workspaces drop column main_session_id;
  delete from schema_migrations where id = 85;
`

export const rewindFreshAgentSessionsSql = `
  alter table sessions drop column fresh_agent_session_id;
  delete from schema_migrations where id = 83;
`

export const rewindPluginsSql = `
  ${rewindFreshAgentSessionsSql}
  drop table plugin_event_deliveries;
  drop table plugin_events;
  drop table plugin_event_cursors;
  drop table plugin_event_subscriptions;
  drop table plugin_app_contexts;
  alter table mcp_servers drop column catalog_id;
  alter table mcp_servers drop column catalog_version;
  alter table mcp_servers drop column capabilities;
  alter table prompt_queue_items drop column attribution;
  alter table chat_items drop column attribution;
  delete from schema_migrations where id = 82;
`
