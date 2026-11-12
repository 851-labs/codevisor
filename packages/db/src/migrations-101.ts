import type { Migration } from "./migration-types.js"

export const migrations101: ReadonlyArray<Migration> = [
  {
    id: 101,
    name: "a chat an agent started can stand alone instead of belonging to its starter",
    sql: `
      drop trigger if exists navigation_sessions_update;
      alter table sessions add column is_detached integer not null default 0;
    `
  }
]
