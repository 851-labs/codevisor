import type { Migration } from "./migration-types.js"

export const migrations69: ReadonlyArray<Migration> = [
  {
    id: 69,
    name: "session event subscriptions",
    sql: `
      alter table chat_items add column origin text;
      create table session_subscriptions (
        id text primary key,
        subscriber_session_id text not null references sessions(id) on delete cascade,
        target_session_id text not null references sessions(id) on delete cascade,
        events text not null,
        once integer not null default 0,
        created_at text not null
      );
      create index session_subscriptions_target_idx on session_subscriptions(target_session_id);
      create index session_subscriptions_subscriber_idx on session_subscriptions(subscriber_session_id);
    `
  }
]
