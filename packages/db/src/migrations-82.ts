import type { Migration } from "./migration-types.js"

export const migrations82: ReadonlyArray<Migration> = [
  {
    id: 82,
    name: "mcp plugins and plugin events",
    sql: `
      alter table mcp_servers add column catalog_id text;
      alter table mcp_servers add column catalog_version text;
      alter table mcp_servers add column capabilities text;
      alter table prompt_queue_items add column attribution text;
      alter table chat_items add column attribution text;

      create table plugin_event_subscriptions (
        id text primary key,
        session_id text not null references sessions(id) on delete cascade,
        server_id text not null references mcp_servers(id) on delete cascade,
        account_id text,
        event_name text not null,
        arguments text not null default '{}',
        filter text,
        explained text not null,
        note text,
        once integer not null default 0,
        created_by text not null check(created_by in ('agent', 'user')),
        paused_reason text,
        created_at text not null
      );
      create index plugin_event_subscriptions_source
        on plugin_event_subscriptions(server_id, event_name);
      create index plugin_event_subscriptions_session on plugin_event_subscriptions(session_id);

      create table plugin_events (
        id text primary key,
        server_id text not null references mcp_servers(id) on delete cascade,
        account_id text not null default '',
        event_name text not null,
        source_event_id text not null,
        occurred_at text not null,
        received_at text not null,
        data text not null,
        unique(server_id, account_id, event_name, source_event_id)
      );
      create index plugin_events_recent on plugin_events(server_id, event_name, received_at);

      create table plugin_event_deliveries (
        subscription_id text not null references plugin_event_subscriptions(id) on delete cascade,
        event_id text not null references plugin_events(id) on delete cascade,
        state text not null check(state in ('pending', 'delivered')),
        created_at text not null,
        primary key (subscription_id, event_id)
      );
      create index plugin_event_deliveries_pending on plugin_event_deliveries(state, created_at);

      create table plugin_event_cursors (
        source_key text primary key,
        cursor text,
        updated_at text not null
      );

      create table plugin_app_contexts (
        session_id text not null references sessions(id) on delete cascade,
        view_id text not null,
        plugin text not null,
        tool text not null,
        context text not null,
        revision integer not null,
        updated_at text not null,
        primary key (session_id, view_id)
      );
    `
  }
]
