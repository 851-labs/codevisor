import type { Migration } from "./migration-types.js"

export const migrations67: ReadonlyArray<Migration> = [
  {
    id: 67,
    name: "bot conversations",
    sql: `
      create table bot_messages (
        id text primary key,
        session_id text not null references sessions(id) on delete cascade,
        sequence integer not null,
        sender text not null,
        text text not null,
        attachments text,
        created_at text not null
      );
      create unique index bot_messages_session_sequence_idx on bot_messages(session_id, sequence);
      alter table prompt_queue_items add column origin text not null default 'user';
    `
  }
]
