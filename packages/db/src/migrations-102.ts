import type { Migration } from "./migration-types.js"

export const migrations102: ReadonlyArray<Migration> = [
  {
    id: 102,
    name: "how each chat's last turn failed",
    sql: `
      alter table session_attention add column last_turn_failure text
        check(last_turn_failure in ('error', 'usageLimit'));
      drop trigger if exists navigation_session_attention_update;
      drop trigger if exists navigation_sessions_update;
    `
  }
]
