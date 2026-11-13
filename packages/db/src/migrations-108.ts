import type { Migration } from "./migration-types.js"

export const migrations108: ReadonlyArray<Migration> = [
  {
    id: 108,
    name: "event subscriptions and events can come from a built-in source, not only a plugin",
    sql: `
      create table plugin_event_subscriptions_next (
        id text primary key,
        session_id text not null references sessions(id) on delete cascade,
        server_id text not null,
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
      insert into plugin_event_subscriptions_next select
        id, session_id, server_id, account_id, event_name, arguments, filter, explained, note, once,
        created_by, paused_reason, created_at
        from plugin_event_subscriptions;
      drop table plugin_event_subscriptions;
      alter table plugin_event_subscriptions_next rename to plugin_event_subscriptions;
      create index plugin_event_subscriptions_source
        on plugin_event_subscriptions(server_id, event_name);
      create index plugin_event_subscriptions_session on plugin_event_subscriptions(session_id);

      create table plugin_events_next (
        id text primary key,
        server_id text not null,
        account_id text not null default '',
        event_name text not null,
        source_event_id text not null,
        occurred_at text not null,
        received_at text not null,
        data text not null,
        unique(server_id, account_id, event_name, source_event_id)
      );
      insert into plugin_events_next select
        id, server_id, account_id, event_name, source_event_id, occurred_at, received_at, data
        from plugin_events;
      drop table plugin_events;
      alter table plugin_events_next rename to plugin_events;
      create index plugin_events_recent on plugin_events(server_id, event_name, received_at);
    `
  }
]
