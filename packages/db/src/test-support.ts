import Database from "better-sqlite3"
import { Effect } from "effect"
import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { afterEach } from "vitest"
import type { DatabaseError } from "./errors.js"

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

/** Recreates the on-disk shape of a database last touched by migration 4. */
export const buildV4Fixture = (filename: string): void => {
  const sqlite = new Database(filename)
  sqlite.exec(`
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
  `)
  sqlite.close()
}
