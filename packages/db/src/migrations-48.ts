import type { Migration } from "./migration-types.js"

export const migrations48: ReadonlyArray<Migration> = [
  {
    id: 48,
    name: "persisted transcript state",
    sql: `
    alter table sessions add column goal_state text;
    alter table sessions add column last_event_at text;
    alter table project_locations add column is_git_repository integer;
    create table sync_watermarks (
      subject_id text primary key,
      floor integer not null default 0,
      bytes integer not null default 0
    );
    create table transcript_entries (
      item_id text not null references chat_items(id) on delete cascade,
      entry_key text not null,
      position integer not null,
      revision integer not null,
      parent_id text not null default '',
        category text not null,
        text_length integer not null default 0,
      phase text,
      payload text not null,
      primary key (item_id, entry_key)
    );
    create index transcript_entries_position on transcript_entries(item_id, position, entry_key);
    create index transcript_entries_answer on transcript_entries(item_id, parent_id, category, phase, position);
    create table transcript_text_chunks (
      item_id text not null,
      entry_key text not null,
      position integer not null,
      char_offset integer not null default 0,
      text text not null,
      primary key (item_id, entry_key, position),
      foreign key (item_id, entry_key) references transcript_entries(item_id, entry_key) on delete cascade
    );
    create table transcript_heads (
      item_id text not null references chat_items(id) on delete cascade,
      parent_id text not null,
      entry_key text not null,
      category text not null,
      primary key (item_id, parent_id)
    );
    create table transcript_body_fields (
      item_id text not null,
      entry_key text not null,
      field text not null,
      revision integer not null,
      encoding text not null,
      size_bytes integer not null,
      primary key(item_id, entry_key, field),
      foreign key(item_id, entry_key) references transcript_entries(item_id, entry_key) on delete cascade
    );
    create table transcript_body_chunks (
      item_id text not null,
      entry_key text not null,
      field text not null,
      position integer not null,
      text text not null,
      primary key(item_id, entry_key, field, position),
      foreign key(item_id, entry_key, field) references transcript_body_fields(item_id, entry_key, field) on delete cascade
    );
    create table setup_state (
      subject_id text not null, kind text not null, revision integer not null,
      created_at text not null, text_length integer not null default 0, payload text not null,
      primary key(subject_id, kind)
    );
    create table setup_text_chunks (
      subject_id text not null, kind text not null, position integer not null, text text not null,
      primary key(subject_id, kind, position),
      foreign key(subject_id, kind) references setup_state(subject_id, kind) on delete cascade
    );
    create table session_state (
      session_id text not null references sessions(id) on delete cascade,
      state_key text not null,
      revision integer not null,
      payload text not null,
      primary key (session_id, state_key)
    );
    create index chat_items_message_cursor on chat_items(session_id, lower(message_id));
    create index chat_items_streaming on chat_items(session_id, position) where status = 'streaming';
  `
  }
]
