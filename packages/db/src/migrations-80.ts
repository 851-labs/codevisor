import type { Migration } from "./migration-types.js"

export const migrations80: ReadonlyArray<Migration> = [
  {
    id: 80,
    name: "turn finish announcements",
    sql: `
      alter table session_attention add column turn_end_state text;
      alter table session_attention add column turn_end_revision integer;
      alter table session_attention add column turn_end_stop_reason text;
      alter table session_attention add column turn_end_item_id text;
      alter table session_attention add column turn_end_at text;
      create index session_attention_finished_turns
        on session_attention(session_id) where turn_end_state = 'finished';
      drop trigger if exists fleet_turn_ended;
    `
  }
]
