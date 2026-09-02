import type { Migration } from "./migration-types.js"

/// Schema migrations 1–8.
export const migrations01To08: ReadonlyArray<Migration> = [
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
  },
  {
    id: 6,
    name: "file attachments",
    sql: `
      create table if not exists files (
        id text primary key,
        name text not null,
        mime_type text not null,
        size_bytes integer not null,
        sha256 text not null,
        kind text not null,
        created_at text not null,
        data blob not null
      );

      alter table conversation_items add column attachments text;
      alter table prompt_queue_items add column attachments text;
    `
  },
  {
    id: 7,
    name: "paginated transcript projection",
    sql: `
      alter table events add column transcript_item_id text;

      create index if not exists events_subject_id_idx on events(subject_id, id);
      create index if not exists events_transcript_item_idx
        on events(subject_id, transcript_item_id, id);

      create table if not exists transcript_items (
        id text primary key,
        session_id text not null references sessions(id) on delete cascade,
        sequence integer not null,
        role text not null check(role in ('user', 'assistant')),
        text text not null default '',
        created_at text not null,
        updated_at text not null,
        is_generating integer not null default 0,
        has_details integer not null default 0,
        turn_id text,
        started_at text,
        ended_at text,
        stop_reason text,
        stop_detail text,
        plan_document text,
        attachments text,
        revision integer not null default 1,
        unique(session_id, sequence),
        unique(session_id, turn_id)
      );

      create index if not exists transcript_items_session_sequence_idx
        on transcript_items(session_id, sequence desc);

      create table if not exists transcript_projection_state (
        session_id text primary key references sessions(id) on delete cascade,
        next_sequence integer not null default 0,
        current_item_id text references transcript_items(id) on delete set null,
        source_cursor integer not null default 0
      );

      create table if not exists transcript_routes (
        session_id text not null references sessions(id) on delete cascade,
        route_key text not null,
        item_id text not null references transcript_items(id) on delete cascade,
        primary key(session_id, route_key)
      );

      alter table backfill_jobs add column completed integer not null default 0;
      alter table backfill_jobs add column total integer not null default 0;
      alter table backfill_jobs add column error text;
    `
  },
  {
    id: 8,
    name: "canonical session chat store",
    sql: `
      alter table sessions add column revision integer not null default 0;

      create table if not exists chat_items (
        id text primary key,
        session_id text not null references sessions(id) on delete cascade,
        position integer not null,
        role text not null check(role in ('user', 'assistant', 'system', 'tool')),
        message_id text,
        status text not null check(status in ('streaming', 'complete', 'failed')),
        created_at text not null,
        updated_at text not null,
        turn_id text,
        started_at text,
        completed_at text,
        stop_reason text,
        stop_detail text,
        attachments text,
        has_details integer not null default 0,
        revision integer not null default 1,
        unique(session_id, position),
        unique(session_id, turn_id)
      );

      create index if not exists chat_items_session_position_idx
        on chat_items(session_id, position desc);

      create table if not exists chat_parts (
        id text primary key,
        item_id text not null references chat_items(id) on delete cascade,
        position integer not null,
        kind text not null,
        text text,
        data_json text,
        revision integer not null default 1,
        unique(item_id, position)
      );

      create index if not exists chat_parts_item_position_idx
        on chat_parts(item_id, position);

      create table if not exists session_chat_state (
        session_id text primary key references sessions(id) on delete cascade,
        next_position integer not null default 0,
        current_item_id text references chat_items(id) on delete set null
      );

      create table if not exists chat_item_routes (
        session_id text not null references sessions(id) on delete cascade,
        route_key text not null,
        item_id text not null references chat_items(id) on delete cascade,
        primary key(session_id, route_key)
      );

      create table if not exists session_events (
        session_id text not null references sessions(id) on delete cascade,
        revision integer not null,
        global_event_id integer unique,
        server_id text not null,
        kind text not null,
        created_at text not null,
        payload text not null,
        chat_item_id text references chat_items(id) on delete set null,
        primary key(session_id, revision)
      );

      create index if not exists session_events_item_idx
        on session_events(session_id, chat_item_id, revision);
    `
  }
]
