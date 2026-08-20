import type Database from "better-sqlite3"
import { randomUUID } from "node:crypto"
import { isRenderableWorkedEvent, parseJsonRecord } from "./event-payloads.js"
import type { CodevisorDatabaseConfig } from "./service.js"

interface Migration {
  readonly id: number
  readonly name: string
  readonly sql: string
  /** Runs inside the migration transaction, after `sql`; use for backfills that need config values. */
  readonly run?: (sqlite: Database.Database, config: CodevisorDatabaseConfig) => void
}

export const migrations: ReadonlyArray<Migration> = [
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
  },
  {
    id: 9,
    name: "harness accounts and session identity",
    sql: `
      create table if not exists harness_accounts (
        id text primary key,
        harness_id text not null,
        profile_kind text not null check(profile_kind in ('default', 'managed')),
        profile_key text,
        label text not null,
        email text,
        organization_id text,
        auth_method text,
        auth_state text not null default 'checking',
        can_login integer not null default 1,
        can_logout integer not null default 0,
        last_checked_at text,
        detail text,
        created_at text not null,
        updated_at text not null,
        removed_at text
      );

      create unique index if not exists harness_accounts_default_idx
        on harness_accounts(harness_id)
        where profile_kind = 'default' and removed_at is null;

      create unique index if not exists harness_accounts_profile_idx
        on harness_accounts(harness_id, profile_key)
        where profile_key is not null and removed_at is null;

      create table if not exists harness_account_selection (
        harness_id text primary key,
        account_id text not null references harness_accounts(id)
      );

      alter table sessions add column harness_account_id text references harness_accounts(id);
      create index if not exists sessions_harness_account_idx on sessions(harness_account_id);
    `
  },
  {
    id: 10,
    name: "accurate worked detail markers",
    sql: "",
    run: (sqlite) => {
      const itemIdsWithDetails = new Set<string>()
      const detailEvents = sqlite
        .prepare(
          `select chat_item_id, payload from session_events
           where chat_item_id is not null and kind = 'session.output'
           order by session_id, revision asc`
        )
        .iterate() as Iterable<{
        readonly chat_item_id: string
        readonly payload: string
      }>
      for (const event of detailEvents) {
        const payload = parseJsonRecord(event.payload)
        if (payload !== undefined && isRenderableWorkedEvent(payload)) {
          itemIdsWithDetails.add(event.chat_item_id)
        }
      }

      const items = sqlite
        .prepare("select id, has_details from chat_items where role = 'assistant'")
        .all() as ReadonlyArray<{ readonly id: string; readonly has_details: number }>
      const updateItem = sqlite.prepare(
        `update chat_items set has_details = ?, revision = revision + 1
         where id = ? and has_details != ?`
      )

      for (const item of items) {
        const value = itemIdsWithDetails.has(item.id) ? 1 : 0
        updateItem.run(value, item.id, value)
      }
    }
  },
  {
    id: 11,
    name: "mcp servers",
    sql: `
      create table if not exists mcp_servers (
        id text primary key,
        name text not null,
        transport text not null check(transport in ('http', 'stdio')),
        url text,
        command text,
        args text not null default '[]',
        enabled integer not null default 1,
        auth_type text not null default 'none' check(auth_type in ('none', 'bearer', 'oauth')),
        oauth_scope text,
        connection_state text not null default 'disconnected',
        tool_count integer not null default 0,
        detail text,
        secret_cipher text,
        created_at text not null,
        updated_at text not null
      );

      create index if not exists mcp_servers_enabled_idx on mcp_servers(enabled);
    `
  },
  {
    id: 12,
    name: "scoped mcp settings",
    sql: `
      create table if not exists project_mcp_settings (
        project_id text not null references projects(id) on delete cascade,
        mcp_server_id text not null references mcp_servers(id) on delete cascade,
        enabled integer not null,
        primary key (project_id, mcp_server_id)
      );

      create table if not exists session_mcp_settings (
        session_id text not null references sessions(id) on delete cascade,
        mcp_server_id text not null references mcp_servers(id) on delete cascade,
        enabled integer not null,
        primary key (session_id, mcp_server_id)
      );
    `
  },
  {
    id: 13,
    name: "durable live session state",
    sql: `
      alter table sessions add column pending_question text;
      alter table sessions add column background_tasks text not null default '[]';
    `
  },
  {
    id: 14,
    name: "durable prompt dispatch",
    sql: `
      alter table prompt_queue_items add column state text not null default 'pending'
        check(state in ('pending', 'processing'));

      create index if not exists prompt_queue_items_session_state_created_idx
        on prompt_queue_items(session_id, state, created_at);
    `
  },
  {
    id: 15,
    name: "retryable assistant turns",
    sql: `
      alter table transcript_items add column retryable integer not null default 0;
      alter table chat_items add column retryable integer not null default 0;
    `
  },
  {
    id: 16,
    name: "Codevisor session origins",
    sql: `
      update projects set origin = 'codevisor' where origin = 'herdman';
      update sessions set origin = 'codevisor' where origin = 'herdman';
      update events
        set payload = json_set(payload, '$.origin', 'codevisor')
        where json_valid(payload) and json_extract(payload, '$.origin') = 'herdman';
      update session_events
        set payload = json_set(payload, '$.origin', 'codevisor')
        where json_valid(payload) and json_extract(payload, '$.origin') = 'herdman';
    `
  },
  {
    id: 17,
    name: "instance identity",
    sql: `
      create table if not exists instance_meta (
        key text primary key,
        value text not null
      );
    `
  },
  {
    id: 18,
    name: "project git remotes",
    sql: `
      alter table projects add column repo_url text;
    `
  },
  {
    id: 19,
    name: "detailed durable session usage",
    sql: `
      alter table sessions add column input_tokens integer;
      alter table sessions add column cached_input_tokens integer;
      alter table sessions add column output_tokens integer;
      alter table sessions add column reasoning_output_tokens integer;
      alter table sessions add column total_tokens integer;
      alter table sessions add column cost_kind text check(cost_kind in ('reported', 'estimated'));
    `
  },
  {
    id: 20,
    name: "user-set session titles",
    sql: `
      alter table sessions add column title_is_user_set integer not null default 0
        check(title_is_user_set in (0, 1));

      -- Older databases did not retain title provenance. Protect every
      -- existing title rather than risk replacing a user-authored one.
      update sessions set title_is_user_set = 1;
    `
  },
  {
    id: 21,
    name: "pane workspaces",
    // Note: an unrelated table also named `workspaces` (the pre-migration-5
    // spelling of projects) was dropped by migration 5, so the name is free
    // on every database that reaches this point.
    sql: `
      create table if not exists workspaces (
        id text primary key,
        server_id text not null,
        project_id text not null references projects(id) on delete cascade,
        name text not null,
        has_custom_name integer not null default 0 check(has_custom_name in (0, 1)),
        symbol_name text,
        root_directory text,
        is_archived integer not null default 0 check(is_archived in (0, 1)),
        created_at text not null,
        updated_at text
      );

      alter table sessions add column workspace_id text references workspaces(id);
      create index if not exists sessions_workspace_id on sessions(workspace_id);
    `
  },
  {
    id: 22,
    name: "workspace notes",
    sql: `
      create table if not exists workspace_notes (
        workspace_id text primary key references workspaces(id) on delete cascade,
        content text not null,
        format text not null default 'attributed-string-v1',
        updated_at text not null
      );
    `
  },
  {
    id: 23,
    name: "harness update state",
    sql: `
      create table if not exists harness_update_state (
        harness_id text primary key,
        installed_version text,
        latest_version text,
        update_available integer not null default 0 check(update_available in (0, 1)),
        source text,
        install_origin text,
        channel text,
        checked_at text
      );
    `
  },
  {
    id: 24,
    name: "harness pending updates",
    sql: `
      create table if not exists harness_pending_updates (
        harness_id text primary key,
        state text not null check(state in ('pending', 'running')),
        target_version text,
        requested_at text not null,
        started_at text,
        timeout_at text
      );
    `
  },
  {
    id: 25,
    name: "native config safety",
    sql: `
      create table if not exists native_config_backups (
        file_path text primary key,
        backup_path text not null,
        created_at text not null
      );

      create table if not exists native_mcp_removals (
        id text primary key,
        harness_id text not null,
        config_path text not null,
        server_name text not null,
        fragment text not null,
        removed_at text not null,
        restored_at text
      );
    `
  },
  {
    id: 26,
    name: "durable session config selections",
    sql: `
      alter table sessions add column config_selections text not null default '{}';
    `
  },
  {
    id: 27,
    name: "built-in automation MCPs",
    sql: `
      alter table mcp_servers add column kind text not null default 'managed'
        check(kind in ('managed', 'browserUse', 'computerUse'));
    `
  },
  {
    id: 28,
    name: "remove automation approvals",
    sql: "drop table if exists automation_target_grants;"
  },
  {
    id: 29,
    name: "disk backed file attachments",
    sql: `
      alter table files add column storage_state text not null default 'sqlite'
        check(storage_state in ('sqlite', 'dual', 'disk'));
    `
  },
  {
    id: 30,
    name: "canonical lowercase uuid ids",
    // UUID ids are compared byte-wise in TEXT columns, but clients disagree on
    // rendering (Swift uppercases, Node lowercases). Sessions never got the
    // lowercase canonicalization projects received, so opening a remotely
    // created (lowercase) session from the macOS app (uppercase paths) missed
    // the existing row and create-if-missing minted a case-twin duplicate —
    // the "duplicate agents/workspaces in the sidebar" bug. This migration
    // makes lowercase canonical everywhere and repairs the damage:
    //  1. Case-twin session groups are merged: twins without any transcript
    //     are phantom forks and are deleted outright; twins that were
    //     genuinely prompted are kept under a fresh lowercase id and archived
    //     so no data is lost but the duplicate leaves the sidebar.
    //  2. Session ids (and their child-table references) are lowercased.
    //  3. Project/worktree/workspace ids and uuid-shaped event subjects are
    //     lowercased where no differently-cased twin row blocks the rename.
    sql: "",
    run: (sqlite) => {
      const sessionChildTables = [
        "conversation_items",
        "session_actions",
        "prompt_queue_items",
        "transcript_items",
        "transcript_projection_state",
        "transcript_routes",
        "chat_items",
        "session_chat_state",
        "chat_item_routes",
        "session_events",
        "session_mcp_settings"
      ]
      const rekeySessionChildren = (from: string, to: string): void => {
        for (const table of sessionChildTables) {
          sqlite.prepare(`update ${table} set session_id = ? where session_id = ?`).run(to, from)
        }
        sqlite.prepare("update events set subject_id = ? where subject_id = ?").run(to, from)
      }
      const hasTranscript = (sessionId: string): boolean =>
        ["chat_items", "transcript_items", "conversation_items"].some(
          (table) =>
            sqlite.prepare(`select 1 from ${table} where session_id = ? limit 1`).get(sessionId) !==
            undefined
        )

      // 1. Merge case-twin sessions. The canonical survivor is the most
      // recently active twin that actually has a transcript (falling back to
      // plain recency when none do).
      const twinGroups = sqlite
        .prepare("select lower(id) as lid from sessions group by lower(id) having count(*) > 1")
        .all() as ReadonlyArray<{ readonly lid: string }>
      for (const group of twinGroups) {
        const rows = sqlite
          .prepare(
            `select id from sessions where lower(id) = ?
             order by coalesce(updated_at, created_at) desc`
          )
          .all(group.lid) as ReadonlyArray<{ readonly id: string }>
        const canonical = (rows.find((row) => hasTranscript(row.id)) ?? rows[0]!).id
        for (const row of rows) {
          if (row.id === canonical) {
            continue
          }
          if (!hasTranscript(row.id)) {
            // A phantom fork: created by a case-missed lookup and never
            // prompted. Dropping it (and its bookkeeping rows) is lossless.
            for (const table of sessionChildTables) {
              sqlite.prepare(`delete from ${table} where session_id = ?`).run(row.id)
            }
            sqlite.prepare("delete from sessions where id = ?").run(row.id)
            continue
          }
          // Both twins were prompted, so their transcripts genuinely forked.
          // Keep the loser's data under a fresh id, archived, instead of
          // guessing how to interleave two histories.
          const fresh = randomUUID()
          rekeySessionChildren(row.id, fresh)
          sqlite
            .prepare("update sessions set id = ?, is_archived = 1 where id = ?")
            .run(fresh, row.id)
        }
      }

      // 2. Lowercase session ids and every child reference. Safe after the
      // merge above: no two remaining sessions share a lowercase id.
      for (const table of sessionChildTables) {
        sqlite.exec(
          `update ${table} set session_id = lower(session_id) where session_id != lower(session_id)`
        )
      }
      sqlite.exec("update sessions set id = lower(id) where id != lower(id)")

      // 3. Projects, worktrees, and workspaces: lowercase ids where no
      // differently-cased twin already claims the lowercase spelling (twins
      // are still served correctly by the nocase project lookups), then align
      // the columns referencing them.
      sqlite.exec(`
        update projects set id = lower(id)
          where id != lower(id)
            and not exists (select 1 from projects twin where twin.id = lower(projects.id));
        update worktrees set id = lower(id)
          where id != lower(id)
            and not exists (select 1 from worktrees twin where twin.id = lower(worktrees.id));
        update workspaces set id = lower(id)
          where id != lower(id)
            and not exists (select 1 from workspaces twin where twin.id = lower(workspaces.id));
        update project_locations set project_id = lower(project_id)
          where project_id != lower(project_id)
            and exists (select 1 from projects where projects.id = lower(project_locations.project_id));
        update worktrees set project_id = lower(project_id)
          where project_id != lower(project_id)
            and exists (select 1 from projects where projects.id = lower(worktrees.project_id));
        update workspaces set project_id = lower(project_id)
          where project_id != lower(project_id)
            and exists (select 1 from projects where projects.id = lower(workspaces.project_id));
        update sessions set project_id = lower(project_id)
          where project_id != lower(project_id)
            and exists (select 1 from projects where projects.id = lower(sessions.project_id));
        update sessions set workspace_id = lower(workspace_id)
          where workspace_id is not null and workspace_id != lower(workspace_id)
            and exists (select 1 from workspaces where workspaces.id = lower(sessions.workspace_id));
        update project_mcp_settings set project_id = lower(project_id)
          where project_id != lower(project_id)
            and not exists (
              select 1 from project_mcp_settings twin
              where twin.project_id = lower(project_mcp_settings.project_id)
                and twin.mcp_server_id = project_mcp_settings.mcp_server_id
            );
        update events set subject_id = lower(subject_id)
          where subject_id != lower(subject_id)
            and subject_id like '________-____-____-____-____________';
      `)
    }
  },
  {
    id: 31,
    name: "durable cross-device session attention",
    sql: `
      create table if not exists session_attention_state (
        session_id text primary key references sessions(id) on delete cascade,
        pending_epoch integer not null default 0 check(pending_epoch in (0, 1)),
        pending_error integer not null default 0 check(pending_error in (0, 1)),
        turn_active integer not null default 0 check(turn_active in (0, 1)),
        runtime_state text not null default 'idle'
          check(runtime_state in ('running', 'idle', 'requires_action')),
        has_runtime_state integer not null default 0 check(has_runtime_state in (0, 1)),
        current_mode_id text,
        pending_plan_approval integer not null default 0
          check(pending_plan_approval in (0, 1))
      );

      create table if not exists session_attention_events (
        session_id text not null references sessions(id) on delete cascade,
        sequence integer not null,
        source_revision integer not null,
        kind text not null check(kind in ('finished', 'action_required')),
        has_error integer not null default 0 check(has_error in (0, 1)),
        created_at text not null,
        primary key(session_id, sequence),
        unique(session_id, source_revision, kind)
      );

      create table if not exists session_read_state (
        session_id text not null references sessions(id) on delete cascade,
        reader_id text not null,
        last_seen_sequence integer not null default 0,
        manually_unread integer not null default 0 check(manually_unread in (0, 1)),
        updated_at text not null,
        primary key(session_id, reader_id)
      );

      create index if not exists session_attention_events_unread_idx
        on session_attention_events(session_id, sequence, has_error);
    `,
    run: (sqlite) => {
      sqlite.exec(`
        insert into session_attention_state (session_id, current_mode_id)
        select s.id, (
          select json_extract(se.payload, '$.modeId')
          from session_events se
          where se.session_id = s.id
            and se.kind = 'session.updated'
            and json_type(se.payload, '$.modeId') = 'text'
          order by se.revision desc limit 1
        )
        from sessions s
        where exists (
          select 1 from session_events se
          where se.session_id = s.id
            and se.kind = 'session.updated'
            and json_type(se.payload, '$.modeId') = 'text'
        )
        on conflict(session_id) do update set current_mode_id = excluded.current_mode_id;
      `)
    }
  },
  {
    id: 32,
    name: "archive timestamps and worktree snapshots",
    /// `is_archived` becomes a derived mirror of `archived_at`: writers set both
    /// so a client from an older release still reads a correct flag, while the
    /// timestamp drives ordering ("archived 2d ago") and cascade provenance.
    ///
    /// `archive_cascade_from` records WHY a row was archived. Unarchiving a
    /// project must revive only the children that same cascade archived — a
    /// chat the user archived by hand weeks earlier stays archived.
    ///
    /// `archived_worktrees` outlives the `worktrees` row on purpose: archiving
    /// frees the worktree name back into the pool immediately, so restore is
    /// keyed by worktree id and remembers the name it would *like* to reclaim.
    sql: `
      alter table projects add column archived_at text;
      alter table workspaces add column archived_at text;
      alter table sessions add column archived_at text;

      alter table workspaces add column archive_cascade_from text;
      alter table sessions add column archive_cascade_from text;

      create table if not exists archived_worktrees (
        id text primary key,
        project_id text not null references projects(id) on delete cascade,
        server_id text not null,
        original_name text not null,
        branch text not null,
        parent_sha text not null,
        snapshot_ref text not null,
        created_at text not null
      );

      create index if not exists archived_worktrees_project_idx
        on archived_worktrees(project_id, server_id, original_name);

      create index if not exists sessions_archived_idx
        on sessions(project_id, archived_at);
    `,
    run: (sqlite) => {
      // Rows archived before this migration have no recorded moment. Stamp them
      // with the repo's oldest meaningful timestamp rather than "now" so the
      // archived list does not claim a years-old chat was archived today.
      sqlite.exec(`
        update projects set archived_at = coalesce(created_at, '1970-01-01T00:00:00.000Z')
          where is_archived = 1 and archived_at is null;
        update workspaces set archived_at = coalesce(created_at, '1970-01-01T00:00:00.000Z')
          where is_archived = 1 and archived_at is null;
        update sessions set archived_at = coalesce(updated_at, created_at, '1970-01-01T00:00:00.000Z')
          where is_archived = 1 and archived_at is null;
      `)
    }
  },
  {
    id: 33,
    name: "drop workspace notes",
    /// The scratchpad feature (a per-workspace notes panel in the macOS
    /// inspector) is gone, so its storage goes with it. Migrations 22 and 30
    /// stay untouched — they already ran on existing installs, and a fresh
    /// database still creates the table there before this migration drops it.
    ///
    /// The stale `workspace.notes.updated` rows are purged too: the event kind
    /// has left the API vocabulary, and the log is replayed to clients from a
    /// cursor, so leaving them would fan out a kind nothing understands.
    sql: `
      drop table if exists workspace_notes;
      delete from events where kind = 'workspace.notes.updated';
    `
  },
  {
    id: 34,
    name: "stable native sidebar state ordering",
    sql: `
      alter table sessions add column sidebar_state text not null default 'idle'
        check(sidebar_state in ('idle', 'inProgress', 'waitingForUser', 'unread', 'errored'));
      alter table sessions add column sidebar_state_changed_at text not null default '';

      update sessions
      set sidebar_state =
        case
          when exists (
            select 1 from session_attention_events ae
            where ae.session_id = sessions.id and ae.has_error = 1
              and ae.sequence > coalesce((
                select last_seen_sequence from session_read_state rs
                where rs.session_id = sessions.id and rs.reader_id = 'owner'
              ), 0)
          ) then 'errored'
          when pending_question is not null or coalesce((
            select pending_plan_approval from session_attention_state ast
            where ast.session_id = sessions.id
          ), 0) = 1 then 'waitingForUser'
          when coalesce((
            select turn_active from session_attention_state ast
            where ast.session_id = sessions.id
          ), 0) = 1
            or coalesce((
              select case when has_runtime_state = 1 and runtime_state = 'running' then 1 else 0 end
              from session_attention_state ast where ast.session_id = sessions.id
            ), 0) = 1
            or exists (
              select 1 from json_each(sessions.background_tasks)
              where json_extract(value, '$.terminalKey') is null
            ) then 'inProgress'
          when exists (
            select 1 from session_attention_events ae
            where ae.session_id = sessions.id
              and ae.sequence > coalesce((
                select last_seen_sequence from session_read_state rs
                where rs.session_id = sessions.id and rs.reader_id = 'owner'
              ), 0)
          ) or coalesce((
            select manually_unread from session_read_state rs
            where rs.session_id = sessions.id and rs.reader_id = 'owner'
          ), 0) = 1 then 'unread'
          else 'idle'
        end,
        sidebar_state_changed_at = coalesce(updated_at, created_at);
    `
  },
  {
    id: 35,
    name: "server owned workspace panes",
    sql: `
      create table workspace_panes (
        id text primary key,
        workspace_id text not null references workspaces(id) on delete cascade,
        provider_id text not null,
        pane_type text not null,
        title text not null,
        resource_kind text,
        resource_id text,
        metadata text check(metadata is null or json_valid(metadata)),
        created_at text not null,
        updated_at text,
        check((resource_kind is null) = (resource_id is null))
      );

      create index workspace_panes_workspace_idx
        on workspace_panes(workspace_id, created_at);
      create unique index workspace_panes_resource_idx
        on workspace_panes(workspace_id, resource_kind, resource_id)
        where resource_kind is not null and resource_id is not null;
      create unique index workspace_panes_session_resource_idx
        on workspace_panes(resource_kind, resource_id)
        where resource_kind = 'session';

      -- Session membership was the old implicit chat-pane registry. Promote
      -- every active assignment so upgraded clients see exactly the tabs an
      -- older client had already shared.
      insert into workspace_panes (
        id, workspace_id, provider_id, pane_type, title,
        resource_kind, resource_id, metadata, created_at, updated_at
      )
      select lower(s.id), lower(s.workspace_id), 'codevisor', 'chat',
        case when s.title = '' then 'Chat' else s.title end,
        'session', lower(s.id), null, s.created_at, s.updated_at
      from sessions s
      where s.workspace_id is not null and s.is_archived = 0;
    `
  },
  {
    id: 36,
    name: "revisioned workspace pane content",
    sql: `
      alter table workspace_panes add column revision integer not null default 1;
    `
  },
  {
    id: 37,
    name: "attention transcript receipt targets",
    sql: `
      alter table session_attention_events add column chat_item_id text
        references chat_items(id) on delete set null;

      update session_attention_events as ae
      set chat_item_id = coalesce(
        (
          select se.chat_item_id from session_events se
          where se.session_id = ae.session_id
            and se.revision = ae.source_revision
        ),
        case when ae.kind = 'finished' then (
          select se.chat_item_id
          from session_events se
          join chat_items ci on ci.id = se.chat_item_id and ci.role = 'assistant'
          where se.session_id = ae.session_id
            and se.revision <= ae.source_revision
            and json_extract(se.payload, '$.turnState') = 'started'
            and se.revision > coalesce((
              select max(previous.source_revision)
              from session_attention_events previous
              where previous.session_id = ae.session_id
                and previous.sequence < ae.sequence
            ), 0)
          order by se.revision desc
          limit 1
        ) end
      );
    `
  },
  {
    id: 38,
    name: "project worktree base branch",
    sql: `
      alter table projects add column worktree_base_remote text;
      alter table projects add column worktree_base_branch text;
    `
  }
]
