import type { Migration } from "./migration-types.js"

export const migrations95: ReadonlyArray<Migration> = [
  {
    id: 95,
    name: "agent tool calls in flight per session",
    sql: `
      alter table session_attention add column agent_calls text not null default '[]';
      drop trigger if exists navigation_session_attention_update;
    `
  }
]
