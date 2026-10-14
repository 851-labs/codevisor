import type { Migration } from "./migration-types.js"

export const migrations57: ReadonlyArray<Migration> = [
  {
    id: 57,
    name: "unavailable session config selections",
    sql: `
      alter table sessions add column unavailable_config_selections text not null default '{}';
      drop trigger if exists navigation_sessions_update;
    `
  }
]
