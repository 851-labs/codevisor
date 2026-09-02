import { isRenderableWorkedEvent, parseJsonRecord } from "./event-payloads.js"
import type { Migration } from "./migration-types.js"

/// Schema migrations 9–29.
export const migrations09To29: ReadonlyArray<Migration> = [
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
  }
]
